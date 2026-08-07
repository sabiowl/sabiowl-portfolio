"""FEAT-516 の 7 model 分の英訳を `scripts/build_master_data_en.py` に供給する。

## 翻訳を「日本語テキスト → 英語」の辞書で持つ理由

`GachaReward` は migration と `_ensure_gacha_rewards()` の 2 経路で作られ、
**行の pk も顔ぶれも install 時期で変わる**。行に紐づけて訳を書くと、
別の DB では対応が取れない。

日本語テキストをキーにすれば、**どの DB から export しても同じ訳が当たる**。
行の生成は export に任せる。
"""

# ── Achievement (key → (name_en, description_en)) ────────────────────────
ACHIEVEMENT = {
    'first_log':      ('First Step',              'Record a habit for the first time'),
    'log_10':         ('Sprouting',               'Record habits 10 times'),
    'log_50':         ('Tree of Habit',           'Record habits 50 times'),
    'log_100':        ('Mark of a Hundred',       'Record habits 100 times'),
    'log_300':        ('Cornerstone',             'Record habits 300 times'),
    'log_500':        ('Keeper of the Rampart',   'Record habits 500 times'),
    'log_1000':       ('A Thousand Layers',       'Record habits 1,000 times'),
    'streak_3':       ('Past the Third Day',      'Record a habit 3 days in a row'),
    'streak_7':       ('Warrior of the Week',     'Record a habit 7 days in a row'),
    'streak_14':      ('A Fortnight at Sea',      'Record a habit 14 days in a row (where habits start to settle)'),
    'streak_30':      ('Iron Will',               'Record a habit 30 days in a row'),
    'streak_60':      ('Two Moons',               'Record a habit 60 days in a row'),
    'streak_100':     ('Traveller of a Hundred Days', 'Record a habit 100 days in a row'),
    'streak_365':     ('Hero of the Rings',       'Record a habit 365 days in a row (the furthest reach)'),
    'level_5':        ('New Adventurer',          'Reach level 5'),
    'level_10':       ('Seasoned',                'Reach level 10'),
    'level_20':       ('Master',                  'Reach level 20'),
    'level_30':       ('A Sage in the Making',    'Reach level 30'),
    'level_50':       ('Hall of Fame',            'Reach level 50'),
    'exp_1000':       ('Spring of Learning',      'Earn 1,000 EXP in total'),
    'exp_5000':       ('Sea of Knowledge',        'Earn 5,000 EXP in total'),
    'exp_20000':      ('Mountain of Experience',  'Earn 20,000 EXP in total'),
    'gacha_1':        ('Trying Your Luck',        'Draw from the gacha for the first time'),
    'gacha_10':       ('Seeker of the Gacha',     'Draw from the gacha 10 times'),
    'friends_1':      ('Made a Friend',           'Make 1 friend'),
    'friends_5':      ('Bonds with Companions',   'Make 5 friends'),
    'multi_habits_3': ('Varied Days',             'Grow 3 habits at the same time'),
    'multi_habits_5': ('Broad Foothills',         'Grow 5 habits at the same time'),
    'perfect_day_1':  ('A Perfect Day',           'Complete every habit in a single day'),
    'perfect_day_10': ('Chain of Perfection',     'Achieve 10 perfect days'),
    'perfect_day_30': ('A Perfect Month',         'Achieve 30 perfect days'),
}

# ── Job (job_id → description_en) ────────────────────────────────────────
JOB_DESCRIPTION = {
    'warrior':          'A well-rounded, classic fighter. Leans toward attack and is easy to handle.',
    'knight':           'A heavily armoured knight. Slow on the ATB but solid in attack — a dependable front line.',
    'monk':             'A fast, multi-hit martial artist. Modest attack power, but uses specials often.',
    'assassin':         'Fast to act and quick to use specials. An assassin in their element.',
    'archer':           'A mid-range bow user. Balanced speed and power make for a steady fighter.',
    'gunner':           'A marksman firing in rapid bursts from a distance. Acts fast and uses specials often.',
    'bard':             'A poet who carries the party with song. Quick to act and heals through the long fight.',
    'healer':           'Built for healing. A cleric who drains part of the damage dealt back as HP.',
    'alchemist':        'A sage who turns the tide with medicine and science. Healing-focused, with specials arriving a little late.',
    'black_mage':       'An offensive mage who commands fire and lightning, landing steady magic damage over time.',
    'blue_mage':        'A dependable magic attacker. Normal attacks carry an added fire effect.',
    'dark_mage':        'A dark mage whose single blows land heavy. Specials fire at 1 for an elegant finish.',
    'necromancer':      'A mage who erodes enemies with the power of darkness. Heavy hits, with specials arriving a little late.',
    'magic_swordsman':  'A swordsman who joins steel and magic. Reliable damage with an added fire effect.',
}

# ── WeaponMaster (key → (name_en, description_en)) ───────────────────────
WEAPON = {
    'starter_sword':       ('Apprentice Sword',      'A blade that sits well in the hand, without a single nick.'),
    'wood_sword':          ('Wooden Sword',          'A wooden practice sword. Light and easy to handle — fitting for a first swing.'),
    'wood_axe':            ('Wooden Axe',            'A wooden practice axe. Plainly made, but the follow-through feels real.'),
    'wood_knife':          ('Wooden Knife',          'A small practice knife carved from wood. For learning the basics of speed.'),
    'wood_spear':          ('Wooden Spear',          'A wooden practice spear. An entry-level weapon for learning to hold your range.'),
    'wood_bow':            ('Wooden Bow',            'A practice bow made from supple young wood. Builds the fundamentals of aim.'),
    'wood_staff':          ('Wooden Staff',          'A plain wooden staff with magic held inside. Essential for practising incantations.'),
    'wood_scythe':         ('Wooden Scythe',         'A wooden practice scythe shaped after a farm tool. The first step toward the reaper.'),
    'wood_lute':           ('Carved Lute',           'A simple hand-carved lute. Its gentle tone lifts your companions.'),
    'hemp_bandage':        ('Hemp Wraps',            'Hand wraps made of hemp cloth. They support a bare-fisted strike.'),
    'glass_flask':         ('Glass Flask',           'A glass flask for alchemical experiments. It breaks easily, so handle it with care.'),
    'practice_foil':       ('Practice Foil',         'A blunted training foil. For learning graceful form.'),
    'apprentice_grimoire': ('Apprentice Grimoire',   "An apprentice mage's grimoire, packed with the basic spells."),
    'bronze_sword':        ('Bronze Sword',          'A light sword for beginners. An entry-level piece worthy of a first swing.'),
    'iron_sword':          ('Iron Sword',            "A common fighter's sword. Same performance as the starter, but bought with your own hands."),
    'iron_small_sword':    ('Iron Short Sword',      'An iron short sword built for ease of use. Suited to quick strikes.'),
    'iron_dagger':         ('Iron Dagger',           'A finely honed iron dagger. A short blade for finding weak points.'),
    'iron_hand_axe':       ('Iron Hand Axe',         'An iron hand axe you can wield one-handed. Boasts solid power.'),
    'iron_thrust_spear':   ('Iron Pike',             'An iron spear built for the single thrust. It commands the distance.'),
    'iron_short_bow':      ('Iron-Braced Short Bow', 'A short bow reinforced with iron. Easy to handle and steady to aim.'),
    'iron_pistol':         ('Iron Pistol',           'A small firearm for practice. An entry-level piece built to tame the recoil.'),
    'iron_knuckle':        ('Iron Knuckles',         'Iron knuckles worn over the fist. They add weight to a bare-handed strike.'),
    'iron_scythe':         ('Iron Scythe',           "A sharp iron scythe. It lands the reaper's blow in earnest."),
    'iron_string_harp':    ('Iron-String Harp',      'A small harp strung with iron. Its clear tone rallies your allies.'),
    'iron_fine_needle':    ('Iron Needle',           'A slender, sharp iron needle for the spellblade’s rites. It allows for precise cuts.'),
    'iron_frame_flask':    ('Iron-Framed Flask',     'A flask reinforced with an iron frame. It makes alchemy safe to practise.'),
    'hunting_rifle':       ('Hunting Rifle',         "A rifle suited to long-range shots. A hunter's proper equipment."),
    'steel_sword':         ('Steel Sword',           'A sword worthy of a seasoned fighter. The finest coin purchase, for building strength from Lv 10.'),
    'mythril_sword':       ('Mythril Sword',         'A rare blade steeped in magic. Available only from the Daily SR gacha.'),
    'dragon_slayer':       ('Dragonslayer',          'The sword that felled the legendary dragon. The strongest gear, available only from the Weekly SSR gacha.'),
}

# ── PuzzleWorldScene (key → (name_en, tagline_en)) ───────────────────────
# tagline はサビの声 (🪶 マーカー付き)。persona guide に従い感嘆符を使わない。
PUZZLE_SCENE = {
    'morning_grassland': ('Summit at Daybreak', 'A morning view where the quiet soaks right through you 🪶'),
    'noon_castle_town':  ('Castle Town at Noon', 'A town slowly waking into its own bustle 🪶'),
    'night_forest_camp': ('Forest Camp at Night', 'A night for pausing beside the fire 🪶'),
}

# ── GachaReward (日本語テキスト → 英語) ──────────────────────────────────
# 行ではなくテキストで持つ (docstring 参照)。
GACHA_NAME = {
    '経験値ボーナス':          'EXP Bonus',
    '大量経験値':              'Large EXP Bonus',
    '特大経験値':              'Huge EXP Bonus',
    'ダイヤ':                  'Diamonds',
    'XPブースト':              'XP Boost',
    'XPブースト×2':            'XP Boost ×2',
    'XPブースト×3':            'XP Boost ×3',
    'XPブースト×5':            'XP Boost ×5',
    'ミスリルの剣':            'Mythril Sword',
    '竜殺しの剣':              'Dragonslayer',
    'レアキャラ (SSR)':        'Rare Character (SSR)',
    'マンスリーキャラ (SSR)':  'Monthly Character (SSR)',
    'キャラ交換券 (SSR)':      'Character Exchange Ticket (SSR)',
    '守護獣 (SR)':             'Guardian Beast (SR)',
    # 旧バージョンの定数で作られた行 (長期稼働インストールに残る)
    '限定称号':                'Limited Title',
    '伝説の称号':              'Legendary Title',
}
GACHA_DETAIL = {
    '未開放キャラから1体':      'One character you have not unlocked yet',
    'ランダム1体':              'One at random',
    'お好きな SSR キャラを 1 体お選びいただけますよ': 'Choose any one SSR character you like',
    '「習慣の守護者」':          '"Guardian of Habits"',
    '「鋼の意志」':              '"Will of Steel"',
    '「習慣の神」':              '"God of Habits"',
}


def gacha_detail_en(ja: str) -> str | None:
    """`EXP +30` / `× 30` / `15分 ×1.5倍` のような定型は規則で訳す。"""
    import re
    if ja in GACHA_DETAIL:
        return GACHA_DETAIL[ja]
    if re.fullmatch(r'EXP \+[\d,]+', ja):
        return ja                                  # 記号のみ、訳す必要なし
    if re.fullmatch(r'ATK \+[\d,]+', ja):
        return ja
    m = re.fullmatch(r'× ?([\d,]+)', ja)
    if m:
        return f'× {m.group(1)}'
    m = re.fullmatch(r'(\d+)分 ×([\d.]+)倍', ja)
    if m:
        return f'{m.group(1)} min ×{m.group(2)}'
    m = re.fullmatch(r'(\d+)時間 ×([\d.]+)倍', ja)
    if m:
        return f'{m.group(1)} h ×{m.group(2)}'
    return None
