"""master data の LLM 一次翻訳を doc/i18n/master_data_en.json に組み立てる。

日本語の原文は `_source_ja.json` (DB からの export) から自動で引く。
ここに手で書くのは **英訳だけ**。原文を転記しないので、
translate_master_data の source 検証に転記ミスで落ちることがない。
"""
import json
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding='utf-8')
REPO = Path('C:/Users/subar/claude/sabiowl')
SRC = json.loads((REPO / 'doc/i18n/_source_ja.json').read_text(encoding='utf-8'))

# 【FEAT-516】7 model 分の英訳。行ではなく key / 日本語テキストで持つ。
sys.path.insert(0, str(REPO / 'scripts'))
from _feat516_translations import (  # noqa: E402
    ACHIEVEMENT, GACHA_NAME, JOB_DESCRIPTION, PUZZLE_SCENE, WEAPON,
    gacha_detail_en,
)

# ── Enemy (24) ───────────────────────────────────────────────────────────
ENEMY = {
    'armored_knight': 'Armored Knight',
    'bat': 'Bat',
    'chimera': 'Chimera',
    'dark_knight': 'Dark Knight',
    'dragon': 'Dragon',
    'fire_demon': 'Fire Demon',
    'giant_slime': 'Giant Slime',
    'goblin': 'Goblin',
    'goblin_king': 'Goblin King',
    'griffin': 'Griffin',
    'ice_witch': 'Ice Witch',
    'leviathan': 'Leviathan',
    'lich_king': 'Lich King',
    'lizard_warrior': 'Lizard Warrior',
    'ogre': 'Ogre',
    'rat': 'Giant Rat',
    'shadow_mage': 'Shadow Mage',
    'skeleton': 'Skeleton',
    'slime': 'Slime',
    'vampire_lord': 'Vampire Lord',
    'void_dragon': 'Void Dragon',
    'weak_goblin': 'Stray Goblin',
    'wolf': 'Dire Wolf',
    'young_orc': 'Young Orc',
}

# ── Character (14) ───────────────────────────────────────────────────────
# tagline は ja が全件空なので対象外。
CHARACTER = {
    'aria': {
        'name_en': 'Aria',
        'role_en': 'Assassin',
        'description_en': (
            'Her smile is a mask, and her sharpest weapon. Ten years after selling '
            'herself to the guild, she no longer remembers the names of her targets. '
            "Yet one child's eyes she cannot forget. For the day she finally settles "
            'that memory, she walks the shadows again today.'
        ),
    },
    'aurum': {
        'name_en': 'Aurum',
        'role_en': 'Alchemist',
        'description_en': 'A sage who turns the tide of battle with medicine and science.',
    },
    'beatrix': {
        'name_en': 'Beatrix',
        'role_en': 'Knight',
        'description_en': (
            'She wears armor not to protect herself, but to protect the smiles of '
            'those she is sworn to guard. Fighting prejudice as a woman knight, she '
            'held her shield straighter than anyone. The children who grew up watching '
            'her back are now her pride.'
        ),
    },
    'cyan': {
        'name_en': 'Cyan',
        'role_en': 'Blue Mage',
        'description_en': (
            'A single page found deep in the forbidden archive changed his life. The '
            'moment he spoke the spell written in the ancient tongue, the world took '
            'on another color. Knowledge is power, and it is also solitude — no one '
            'can walk alongside the one who knows everything.'
        ),
    },
    'faye': {
        'name_en': 'Faye',
        'role_en': 'Archer',
        'description_en': (
            'His master left him one lesson: an arrow never returns once loosed, so '
            'stake everything before you loose it. A thousand days of solitary '
            'training in the forest sharpened his eye and his arm beyond measure. '
            'Past the point of never missing lies a place only he can see.'
        ),
    },
    'fia': {
        'name_en': 'Fia',
        'role_en': 'Bard',
        'description_en': 'A poet who carries her companions with her singing voice.',
    },
    'irene': {
        'name_en': 'Irene',
        'role_en': 'Necromancer',
        'description_en': 'A mage who wears her enemies down with the power of darkness.',
    },
    'kyle': {
        'name_en': 'Kyle',
        'role_en': 'Spellblade',
        'description_en': 'A swordsman who wields steel and magic in equal measure.',
    },
    'lucia': {
        'name_en': 'Lucia',
        'role_en': 'White Mage',
        'description_en': (
            'The light that heals grows warmer the more deeply its bearer has been '
            'wounded. An illness in childhood turned her toward medicine, and the '
            'tragedies of the battlefield made her a field healer. As long as someone '
            'is suffering, her hands will not stop.'
        ),
    },
    'luna': {
        'name_en': 'Luna',
        'role_en': 'Gunner',
        'description_en': 'A markswoman who fires in rapid bursts from a distance.',
    },
    'noir': {
        'name_en': 'Noir',
        'role_en': 'Dark Mage',
        'description_en': (
            'As the price of forbidden power, she chose solitude. Magic that could '
            'break the balance of the world is held in check by her will alone. She '
            'keeps others at a distance not out of coldness — but because there is '
            'something she wants to protect.'
        ),
    },
    'rune': {
        'name_en': 'Rune',
        'role_en': 'Black Mage',
        'description_en': (
            'A mage who unsealed a forbidden grimoire and now carries a black flame '
            'within.'
        ),
    },
    'sol': {
        'name_en': 'Sol',
        'role_en': 'Warrior',
        'description_en': (
            'As a child, he swore an oath in the flames that took his village: never '
            'again would he feel that helplessness. Scars from every battlefield he '
            'has crossed cover his body, yet the hand that grips his sword has never '
            'once trembled. His blade speaks before his words do — that is his way.'
        ),
    },
    'zenon': {
        'name_en': 'Zenon',
        'role_en': 'Monk',
        'description_en': (
            'Ten years in the mountains taught him that strength is not an explosion '
            'but a way of breathing. The boy who dreamed of splitting the sky with one '
            'blow is now a seeker who steadies his breath with every strike. The '
            'answer lies between motion and stillness — that is the way of the monk.'
        ),
    },
}

# ── SabiMessage (95) ─────────────────────────────────────────────────────
# サビの声。感嘆符を使わない / 二人称は you / 地層・一石・羽・航路の比喩を残す
# (doc/design/i18n_persona_en.md)。
SABI = {
    # context_comeback
    67: 'You meant to rest, and yet your body moved on its own. That is what a habit looks like.',
    68: 'You had decided to rest today, and yet here you are. That contradiction is the heart of continuing.',
    69: "I did say not to push yourself. Still, I'll make sure your coming here is written down.",
    # context_default
    70: 'There is no perfect moment to begin. This moment, today, is the one.',
    71: "Continuing something small is harder than changing something large. You're doing the harder of the two.",
    72: "I'm always here. Come by even when you have no errand.",
    # context_rest_day
    64: 'Choosing to rest is a wise judgment, I think. Recovering in body and mind is its own kind of building.',
    65: 'If you feel tired, that is a letter from your own body asking you to stop. Please rest today.',
    66: 'After strain comes recovery. That law holds for everything.',
    # context_undo
    73: "Ah, you're correcting the record. That honesty is the shortest path to real growth.",
    74: 'An undo is a sign of your will toward accuracy. I honor that honesty.',
    75: "You don't mind tidying the record. That is the mindset of someone who lasts.",
    76: "You aren't afraid to correct the numbers. That humility builds an unshakable foundation.",
    77: 'Accuracy and honesty are the two wheels of a fine accumulation.',
    # home_all_done
    8: 'A truly fine accumulation. I feel proud as well.',
    9: "You brought today to an honest close. Let's acknowledge it quietly.",
    10: "You didn't chase perfection, and the day turned out perfect all the same.",
    11: 'Each of these stones will become an unshakable stratum in time.',
    12: 'Today you kept a promise to yourself. There is little more worth being proud of.',
    13: 'Not the result, but the time you spent facing it — that is what has become your wealth.',
    14: "Please take your time with the afterglow of what you've done. That, too, is part of the building.",
    15: "The change isn't showy, but it is certain. I can see it.",
    16: "You've gained one more reason to trust yourself today.",
    17: "What you finished doesn't disappear. It becomes the foundation of tomorrow's you.",
    18: 'The you of the future will be grateful to the you of today.',
    19: 'A well-ordered day is completed just like this, quietly.',
    # home_early_level
    45: 'There is no need to hurry. Even a great tree began as a small shoot.',
    46: "The beginning is what wears on you most. I'll be watching over you from beside you.",
    47: 'You came back here again. I have respect for that will.',
    48: "The first few weeks are the heaviest. Once you are past them, it grows lighter on its own.",
    49: "The only rival worth measuring yourself against is yesterday's you.",
    50: 'The moment you took the first step, you were already halfway across.',
    # home_high_level
    39: 'Few people ever come this far. You have my admiration.',
    40: "The time you have built up is wealth no one can take from you now.",
    41: "I'm watching the art of continuing from the best seat in the house.",
    42: 'The view from this height is a reward kept for those who built their way up to it.',
    43: 'The road you have walked will become a landmark for someone who is only starting out.',
    44: 'For someone who has come this far, there is little left for me to say.',
    # home_knowledge_general
    52: 'A new habit takes about 66 days to settle, on average. The twenty-one-day figure is only a rough guide.',
    53: 'Research suggests that deciding on a few times a week is easier to sustain than every day. Flexibility leads to strength.',
    54: 'Deciding on a cue makes a habit settle remarkably well. Link the signal to the action — a glass of water when you wake, for instance.',
    55: 'Arranging your surroundings is far more efficient than training your willpower. Reducing friction lasts longer.',
    56: 'Deciding to begin for just two minutes tends to carry you much further. Once you have started, momentum takes your side.',
    57: 'Perfectionism is the greatest enemy of continuing. Sixty points every day is far stronger than a hundred points once a week.',
    58: "Interrupted habits return most often for those who didn't treat the break as a failure. A single gap means nothing.",
    59: 'Willpower is said to be most abundant in the morning. The habits that matter most settle best when placed early.',
    60: 'Reframing it as becoming the kind of person who does this steadies the behavior remarkably. You already are that person.',
    61: 'Build things so the reward arrives right after the action, and the mind follows willingly. That is the heart of habit-forming.',
    62: 'Rest one day, but never two in a row. That alone is said to prevent most falls.',
    63: 'While you sleep, your mind sorts what it has gathered and prepares for tomorrow. Sleeping well is a fine habit in its own right.',
    # home_no_habits
    1: 'One step first. That very first step is the most precious of all.',
    2: 'Would you like to leave your first footprints on a blank map?',
    3: 'Within the quiet, the first signs of change are sleeping.',
    4: 'There is value in the silence before something takes shape. Thinking is already a beginning.',
    5: 'Hesitation is part of choosing. The road you walk is yours to draw.',
    6: 'The courage to write the first line and the courage to take the first step resemble each other closely.',
    7: 'The freedom not to begin and the freedom to begin are both yours.',
    # home_none_done
    30: 'Having a reason to stop is human enough.',
    31: "Today you chose to do nothing. Let's see it that way, and wait for tomorrow.",
    32: 'Resting your wings is a necessary stage of flying a long way.',
    33: "This is time for gathering strength. Let's store up what the next flight will need.",
    34: "A day you couldn't move is still your day. That is part of your voyage too.",
    35: "So that tomorrow's you does not blame today's, I'll affirm today's you on your behalf.",
    36: "Habits are built up. Resting a day doesn't erase what you have built.",
    37: "You came — that alone is enough. The will to continue hasn't gone out.",
    38: 'It is because there are days you stand still that the days you move forward stand out.',
    # home_partial
    20: "It's all right. You are doing quite enough.",
    21: "You didn't stop walking. That fact alone is the finest harvest.",
    22: 'Little by little, but surely. That is the secret to lasting.',
    23: "If you finished even one, it's fair to call that a victory.",
    24: "Some days you finish everything, and some days you don't. That is what continuing means.",
    25: "You didn't stop partway. That judgment is the watershed of lasting.",
    26: 'Not chasing a hundred points, but continuing at sixty. In the end, that road carries you the furthest.',
    27: "Please think of what's left as an invitation to tomorrow.",
    28: 'If you moved even one step, you are a different person from the one who stood still.',
    29: 'Give yourself credit for as much as you managed. That is the manner of someone who continues.',
    # home_pun
    51: 'Little by little turns out to be the biggest little secret to opening up a life.',
    # time_early_morning
    78: 'Awake and moving at such an early hour. I am impressed.',
    79: 'Marking the record quietly, in the quiet of morning. That becomes the foundation of the day.',
    80: 'Waking before dawn and setting out. That is no ordinary will.',
    # time_evening
    87: 'How was your day today?',
    88: 'You stopped by in the evening light. That alone is enough.',
    89: 'The end of the day is drawing near. Take care with how you close it.',
    # time_late_night
    93: 'I am here even at this late hour.',
    94: 'Staying up is hard on the body, though I am glad you came.',
    95: 'A habit kept late at night is proof of a strong will.',
    # time_morning
    81: 'Good morning. May today be a good day for you.',
    82: 'Move in the morning, and the day grows richer.',
    83: 'You have come at the hour of beginnings. That is a fine habit.',
    # time_night
    90: 'You have done your work well today.',
    91: "What you build at night becomes tomorrow's nourishment.",
    92: 'It seems you are facing yourself in the quiet hours of the night.',
    # time_noon
    84: 'We have come into the afternoon. How are you finding it?',
    85: 'This is the turning point of the day. A gentle pace is perfectly fine.',
    86: 'There are things built under the midday sun as well. Let us go without hurrying.',
}

# ── TaskSuggestion (title 126 + hint 6) ──────────────────────────────────
TASK_TITLE = {
    1: 'Morning run', 2: 'Reading time', 3: 'Stretching', 4: 'Break time',
    5: 'Focused work', 6: 'Meeting', 7: 'Lunch', 8: 'Reflection note',
    9: 'Hobby time', 10: 'Walking',
    11: 'Drink a glass of water', 12: 'Open one page of a book',
    13: 'Breathe deeply for five minutes', 14: "Note down today's events",
    15: 'Tidy just one spot in the room', 16: 'Tell someone thank you',
    27: 'Dinner', 28: 'Head to work', 29: 'Remote work', 30: 'Head out',
    31: 'Client meeting', 32: 'Interview', 33: 'Presentation',
    34: 'Planning meeting', 35: 'Sales call', 36: 'Overtime', 37: 'Commute',
    38: 'Bath', 39: 'Bedtime', 40: 'Gym', 41: 'Shopping', 42: 'Date',
    43: 'Supermarket', 44: 'Convenience store', 45: 'Drugstore',
    46: 'Amazon order', 47: 'Online shopping', 48: 'Hospital', 49: 'Dentist',
    50: 'Hair salon', 51: 'Post office', 52: 'Bank', 53: 'City hall',
    54: 'Cherry blossom viewing', 55: 'Holiday trip', 56: 'Summer festival',
    57: 'Obon holiday', 58: 'Halloween', 59: 'Christmas', 60: 'Deep cleaning',
    61: "New Year's shrine visit",
    62: 'Go to the hospital', 63: 'Take medicine',
    64: 'Book a dentist appointment', 65: 'Book a health check-up',
    66: 'Submit an assignment', 67: 'Write a report',
    68: 'Watch an online lecture', 69: 'Take a practice exam',
    70: 'Reply to emails', 71: 'Prepare materials', 72: 'Create an invoice',
    73: 'Create a quote', 74: 'Make a phone call', 75: 'Organize tasks',
    76: 'Buy detergent', 77: 'Buy groceries', 78: 'Go to the dry cleaner',
    79: 'Pick up a delivery', 80: 'Go to the bank', 81: 'Make a transfer',
    82: 'Pay the credit card bill', 83: 'Pay rent', 84: 'Reply to messages',
    85: 'Morning stretch, 5 min', 86: 'Read for 15 minutes',
    87: 'Drink 2 L of water', 88: 'Learn 10 new words', 89: 'Walk for 20 minutes',
    90: 'Write in a journal', 91: 'Reach out to family or friends',
    92: 'Gym once a week', 93: 'Tidy the room',
    94: 'Try something new once a month',
    95: 'Brush your teeth', 96: 'Take supplements', 97: 'Drink a protein shake',
    98: 'Weigh yourself', 99: 'Check your blood pressure',
    100: 'Log your sleep', 101: 'Stay smoke-free', 102: 'Stay alcohol-free',
    103: 'Take vitamins', 104: '20 squats', 105: '30 sit-ups',
    106: '10 push-ups', 107: 'Morning exercises', 108: 'Meditate for 10 minutes',
    109: 'Yoga for 15 minutes', 110: 'Study for a certification, 30 min',
    111: 'Code for 30 minutes', 112: 'Language practice', 113: 'Read the news',
    114: 'Read the newspaper', 115: 'Work through practice problems',
    116: 'Review what you learned',
    117: 'Laundry', 118: 'Vacuum', 119: 'Take out the trash',
    120: 'Wash the dishes', 121: 'Cook at home', 122: 'Pack a lunch',
    123: 'Clean the washbasin', 124: 'Clean the toilet',
    125: 'Update the budget', 126: 'Review your spending',
    127: 'Check your investments', 128: 'Sort receipts',
    129: 'Play a game', 130: 'Watch a movie', 131: 'Watch anime',
    132: 'Read a manga', 133: 'Listen to music', 134: 'Practice an instrument',
    135: 'Take photos', 136: 'Draw something',
}
TASK_HINT = {
    11: 'The first step',
    12: 'An investment in yourself',
    13: 'Settle your mind',
    14: 'A habit of looking back',
    15: 'A small tidying',
    16: "Today's kindness",
}


def build():
    out, missing = {}, []

    out['Enemy'] = []
    for row in SRC['Enemy']:
        en = ENEMY.get(row['key'])
        if not en:
            missing.append(f"Enemy {row['key']}")
            continue
        out['Enemy'].append({'key': row['key'], 'name': row['name'], 'name_en': en})

    out['Character'] = []
    for row in SRC['Character']:
        tr = CHARACTER.get(row['key'])
        if not tr:
            missing.append(f"Character {row['key']}")
            continue
        entry = {'key': row['key']}
        for base in ('name', 'role', 'description'):
            entry[base] = row[base]          # source 検証用
            entry[f'{base}_en'] = tr[f'{base}_en']
        out['Character'].append(entry)

    out['SabiMessage'] = []
    for row in SRC['SabiMessage']:
        en = SABI.get(row['id'])
        if not en:
            missing.append(f"SabiMessage {row['id']}")
            continue
        out['SabiMessage'].append(
            {'id': row['id'], 'content': row['content'], 'content_en': en}
        )

    out['TaskSuggestion'] = []
    for row in SRC['TaskSuggestion']:
        title_en = TASK_TITLE.get(row['id'])
        if not title_en:
            missing.append(f"TaskSuggestion {row['id']}")
            continue
        entry = {'id': row['id'], 'title': row['title'], 'title_en': title_en}
        if row['hint'].strip():
            hint_en = TASK_HINT.get(row['id'])
            if not hint_en:
                missing.append(f"TaskSuggestion.hint {row['id']}")
            else:
                entry['hint'] = row['hint']
                entry['hint_en'] = hint_en
        out['TaskSuggestion'].append(entry)

    # ── 【FEAT-516】7 model ────────────────────────────────────────────
    out['Achievement'] = []
    for row in SRC.get('Achievement', []):
        tr = ACHIEVEMENT.get(row['key'])
        if not tr:
            missing.append(f"Achievement {row['key']}")
            continue
        out['Achievement'].append({
            'key': row['key'],
            'name': row['name'], 'name_en': tr[0],
            'description': row['description'], 'description_en': tr[1],
        })

    out['Job'] = []
    for row in SRC.get('Job', []):
        en = JOB_DESCRIPTION.get(row['job_id'])
        if not en:
            missing.append(f"Job {row['job_id']}")
            continue
        out['Job'].append({
            'job_id': row['job_id'],
            'description': row['description'], 'description_en': en,
        })

    out['WeaponMaster'] = []
    for row in SRC.get('WeaponMaster', []):
        tr = WEAPON.get(row['key'])
        if not tr:
            missing.append(f"WeaponMaster {row['key']}")
            continue
        out['WeaponMaster'].append({
            'key': row['key'],
            'name': row['name'], 'name_en': tr[0],
            'description': row['description'], 'description_en': tr[1],
        })

    out['PuzzleWorldScene'] = []
    for row in SRC.get('PuzzleWorldScene', []):
        tr = PUZZLE_SCENE.get(row['key'])
        if not tr:
            missing.append(f"PuzzleWorldScene {row['key']}")
            continue
        out['PuzzleWorldScene'].append({
            'key': row['key'],
            'name': row['name'], 'name_en': tr[0],
            'tagline': row['tagline'], 'tagline_en': tr[1],
        })

    # GachaReward は行の顔ぶれが install 時期で変わるので、日本語テキストで引く。
    #
    # 【2026-08-07】`id` の出力をやめた。GachaReward の行は migration ではなく
    # 実行時 (`views/gacha.py` の `_ensure_gacha_rewards()`) に seed されるため、
    # pk が DB backend で変わる (SQLite は解放された rowid を再利用、PostgreSQL の
    # シーケンスは再利用しない)。そのせいで同じファイルが SQLite では 19 行に
    # 当たり PostgreSQL では 6 行にしか当たらず、CI が落ちていた。
    # 照合は translate_master_data の `_COMPOSITE_KEYS` が (name, detail) で行う。
    #
    # 同じ (name, detail) が daily / weekly の両方にある場合は 1 entry にまとめる。
    # 訳は日本語テキストの関数なので、投入側が該当する全行に同じ訳を入れる。
    out['GachaReward'] = []
    _seen_gacha = set()
    for row in SRC.get('GachaReward', []):
        name_en = GACHA_NAME.get(row['name'])
        detail_en = gacha_detail_en(row['detail'])
        if name_en is None:
            missing.append(f"GachaReward name {row['name']!r}")
            continue
        if detail_en is None:
            missing.append(f"GachaReward detail {row['detail']!r}")
            continue
        dedupe_key = (row['name'], row['detail'])
        if dedupe_key in _seen_gacha:
            continue
        _seen_gacha.add(dedupe_key)
        out['GachaReward'].append({
            'name': row['name'], 'name_en': name_en,
            'detail': row['detail'], 'detail_en': detail_en,
        })

    # Challenge / MaintenanceConfig は admin が運用中に作るので通常 0 行。
    # 行が現れたら未翻訳として報告される (訳を足すか、運用で en を直接入れる)。
    for model in ('Challenge', 'MaintenanceConfig'):
        for row in SRC.get(model, []):
            missing.append(f"{model} id={row['id']} (運用データ、要個別対応)")

    return out, missing


data, missing = build()
dest = REPO / 'doc/i18n/master_data_en.json'
dest.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding='utf-8')

n = sum(
    sum(1 for k in e if k.endswith('_en'))
    for rows in data.values() for e in rows
)
for model, rows in data.items():
    print(f'{model:<16} {len(rows):>4} 行')
print(f'{"翻訳 field 数":<14} {n:>4}')
if missing:
    print('\n未翻訳:', missing)
    sys.exit(1)
print('\n未翻訳なし')
