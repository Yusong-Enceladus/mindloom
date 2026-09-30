# Per-process shim (only via PYTHONPATH for the Mistral Small 4 server): vLLM 0.30.0's pixtral module imports
# names that transformers 5.x renamed or removed. Restore them from transformers 4.x behaviour.
try:
    import torch as _torch
    import transformers.models.pixtral.modeling_pixtral as _m
    if not hasattr(_m, "PixtralRotaryEmbedding") and hasattr(_m, "PixtralVisionRotaryEmbedding"):
        _m.PixtralRotaryEmbedding = _m.PixtralVisionRotaryEmbedding
    if not hasattr(_m, "position_ids_in_meshgrid"):
        def position_ids_in_meshgrid(patch_embeds_list, max_width):
            positions = []
            for patch in patch_embeds_list:
                height, width = patch.shape[-2:]
                mesh = _torch.meshgrid(_torch.arange(height), _torch.arange(width), indexing="ij")
                h_grid, v_grid = _torch.stack(mesh, dim=-1).reshape(-1, 2).chunk(2, -1)
                ids = h_grid * max_width + v_grid
                positions.append(ids[:, 0])
            return _torch.cat(positions)
        _m.position_ids_in_meshgrid = position_ids_in_meshgrid
except Exception:
    pass
