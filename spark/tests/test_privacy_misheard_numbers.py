"""A card or ID-card number the speech recognizer heard wrong in one digit fails its checksum (Luhn, the ID
check character). Masking decides on the number's shape, not on the checksum, so such a number is masked too.
The checksum only picks the label. Invented numbers only."""

from __future__ import annotations

import pytest

from organizer import masking

KEY = bytes([0x11]) * 32

# Synthetic: Luhn-valid cards (network prefix 62, 4, 51-55, 34/37) and a valid-check ID number.
CARD_16 = "6222021234567894"
CARD_19 = "6228480012345678903"
CARD_VISA = "4111111111111111"
CARD_AMEX = "378282246310005"
ID_18 = "11010519491231002X"


def mutations(number: str, keep_prefix: int = 0):
    """Every number with exactly one digit replaced by a different digit."""
    for i, ch in enumerate(number):
        if i < keep_prefix or not ch.isdigit():
            continue
        for d in "0123456789":
            if d != ch:
                yield number[:i] + d + number[i + 1:]


def spans(text: str):
    return [(s["type"], s["original"]) for s in masking.mask(text, KEY)[1]]


def test_luhn_and_id_fixtures_are_valid_before_they_are_changed():
    for card in (CARD_16, CARD_19, CARD_VISA, CARD_AMEX):
        assert masking._luhn_ok(card)
    assert masking._id_ok(ID_18)


@pytest.mark.parametrize("card", [CARD_16, CARD_19, CARD_VISA])
def test_every_one_digit_error_in_a_card_after_a_card_word_is_masked(card):
    for wrong in mutations(card):
        masked = masking.mask("我的卡号 " + wrong + " 麻烦转一下", KEY)[0]
        assert wrong not in masked, wrong
        assert "〔银行卡号" in masked


@pytest.mark.parametrize("card", [CARD_16, CARD_19, CARD_VISA])
def test_a_one_digit_error_that_keeps_the_network_prefix_is_masked_without_a_card_word(card):
    for wrong in mutations(card, keep_prefix=2):
        masked = masking.mask("转到 " + wrong + " 这个", KEY)[0]
        assert wrong not in masked, wrong


def test_grouped_and_wrapped_cards_with_an_error():
    for wrong in mutations("6222 0212 3456 7890", keep_prefix=0):
        assert spans("信用卡 " + wrong) == [("bank_card", wrong)], wrong
    assert spans("卡号 6222 0212\n3456 7895") == [("bank_card", "6222 0212\n3456 7895")]


def test_amex_with_an_error():
    for wrong in mutations("3782 822463 10005", keep_prefix=2):
        assert spans("Amex card " + wrong) == [("bank_card", wrong)], wrong


def test_every_one_digit_error_in_an_id_number_after_an_id_word_is_masked():
    for wrong in mutations(ID_18, keep_prefix=0):
        masked = masking.mask("身份证号是" + wrong, KEY)[0]
        assert wrong not in masked, wrong
        assert "〔身份证号" in masked
    # the check character heard as another character
    for ch in "0123456789X":
        wrong = ID_18[:17] + ch
        assert spans("身份证号 " + wrong) == [("id_card", wrong)]


def test_an_id_number_with_a_wrong_check_character_is_masked_without_an_id_word():
    wrong = "110105194912310021"
    assert spans("编号 " + wrong) == [("id_card", wrong)]
    assert spans("110101 19900307 1235") == [("id_card", "110101 19900307 1235")]


def test_a_misheard_number_and_the_right_one_are_both_masked_with_different_tags():
    text = "卡号 6222 0212 3456 7894，再说一遍 6222 0212 3456 7895"
    masked = masking.mask(text, KEY)[0]
    assert masked.count("〔银行卡号·") == 2
    assert len(set(masking.PLACEHOLDER_RX.findall(masked))) == 2


def test_the_checksum_picks_the_label_between_id_and_card():
    both = "624262199802059972"  # passes Luhn, fails the ID check, starts like a card
    assert masking._luhn_ok(both) and not masking._id_ok(both)
    assert spans("收款 " + both) == [("bank_card", both)]
    assert spans("身份证号 " + ID_18) == [("id_card", ID_18)]


@pytest.mark.parametrize(
    "text",
    [
        "订单号 2026092912345678 已发货",
        "编号 1234567812345671 只是批次号，校验也不对",
        "编号 110107200113293214（13 月不是日期，没有证件词）",
        "组会改到 2026-09-29 14:30，地点 B203",
        "截止 20260929 23:59 AoE",
        "预算 ¥12,800.00，已付 ¥3,200，余 ¥9,600.00",
        "客服 400-820-8820，工作日 9:00-18:00",
        "流水 20260929123 已入账",
        "序列号 ABC4111111111111111",
    ],
)
def test_dates_times_amounts_and_plain_numbers_stay(text):
    assert masking.mask(text, KEY) == (text, [])
