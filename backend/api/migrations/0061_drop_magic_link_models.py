from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0060_drop_lantern'),
    ]

    operations = [
        # FEAT-178: メール認証廃止に伴い MagicLinkToken / SocialPendingMerge を drop。
        # SocialAccount は残す（Google / Apple サインインで継続利用）。
        migrations.DeleteModel(name='MagicLinkToken'),
        migrations.DeleteModel(name='SocialPendingMerge'),
    ]
