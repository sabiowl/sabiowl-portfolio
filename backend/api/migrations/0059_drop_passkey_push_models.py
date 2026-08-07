from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0058_magiclinktoken_failed_attempts'),
    ]

    operations = [
        # PasskeyCredential（FK → User、CASCADE）
        migrations.DeleteModel(name='PasskeyCredential'),
        # PendingChallenge（独立テーブル、challenge 一時保存用）
        migrations.DeleteModel(name='PendingChallenge'),
        # PushSubscription（FK → PlayerProfile、CASCADE）
        migrations.DeleteModel(name='PushSubscription'),
    ]
