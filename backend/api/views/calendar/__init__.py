"""【FEAT-290】calendar.py (旧 1110 LOC 単一ファイル) 分割パッケージ。

旧 `backend/api/views/calendar.py` を機能別 3 モジュールに分割:
    - aggregations.py    : 集計系 3 view (CalendarView / StreakView / StatsView)
                           ※ 旧 MonthlySummaryView は 20260729 review §3 C-1 で
                           削除 (Mobile 側クライアント計算に一元化、grade 閾値
                           drift 解消)
    - external_sync.py   : Google 連携 2 view (ExternalCalendarImportView /
                           GoogleCalendarUnsyncView) — いずれも FEAT-426 で
                           410 Gone deprecation スタブ化済
    - core.py            : 細部 + orchestrator 4 view (CalendarHeatmapView /
                           CalendarDailyView / CalendarBootstrapView /
                           Stats30DayView)

本 `__init__.py` で全 view を re-export することで、
`from api.views import calendar` 配下の旧 import パターンを 100% 維持。
`urls.py` 変更ゼロ、Flutter 側 fromJson 影響ゼロ。

関連: FEAT-268 (Flutter 側 calendar 分割) の Backend 側対称化、
      FEAT-290 (`doc/instructions/FEAT-290_calendar_views_split.md`)。
"""
from .aggregations import (
    CalendarView,
    StreakView,
    StatsView,
)
from .external_sync import (
    ExternalCalendarImportView,
    GoogleCalendarUnsyncView,
)
from .core import (
    CalendarHeatmapView,
    CalendarDailyView,
    CalendarBootstrapView,
    Stats30DayView,
)
from .google_completion import (
    GoogleEventCompletionListView,
    GoogleEventCompletionView,
)

__all__ = [
    # aggregations (MonthlySummaryView は 20260729 review §3 C-1 で削除)
    'CalendarView',
    'StreakView',
    'StatsView',
    # external_sync
    'ExternalCalendarImportView',
    'GoogleCalendarUnsyncView',
    # core
    'CalendarHeatmapView',
    'CalendarDailyView',
    'CalendarBootstrapView',
    'Stats30DayView',
    # google_completion (FEAT-426)
    'GoogleEventCompletionListView',
    'GoogleEventCompletionView',
]
