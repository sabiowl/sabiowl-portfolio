from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('api', '0047_socialaccount'),
    ]

    operations = [
        migrations.AddField(
            model_name='magiclinktoken',
            name='purpose',
            field=models.CharField(
                choices=[('login', 'ログイン'), ('link', 'メール連携')],
                default='login',
                max_length=10,
                verbose_name='用途',
            ),
        ),
        migrations.AddField(
            model_name='magiclinktoken',
            name='link_user',
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.CASCADE,
                related_name='email_link_tokens',
                to=settings.AUTH_USER_MODEL,
                verbose_name='連携先ユーザー',
            ),
        ),
    ]
