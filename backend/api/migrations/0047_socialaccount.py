from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('api', '0046_habitrewardlog'),
    ]

    operations = [
        migrations.CreateModel(
            name='SocialAccount',
            fields=[
                ('id', models.BigAutoField(
                    auto_created=True, primary_key=True,
                    serialize=False, verbose_name='ID')),
                ('provider', models.CharField(
                    choices=[('google', 'Google'), ('apple', 'Apple')],
                    max_length=10, verbose_name='プロバイダー')),
                ('provider_uid', models.CharField(
                    max_length=128, unique=True,
                    verbose_name='プロバイダーUID')),
                ('email', models.EmailField(
                    blank=True, verbose_name='メールアドレス')),
                ('created_at', models.DateTimeField(
                    auto_now_add=True, verbose_name='登録日時')),
                ('user', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='social_accounts',
                    to=settings.AUTH_USER_MODEL,
                    verbose_name='ユーザー')),
            ],
            options={
                'verbose_name': 'ソーシャルアカウント',
                'verbose_name_plural': 'ソーシャルアカウント',
                'indexes': [
                    models.Index(
                        fields=['provider', 'provider_uid'],
                        name='api_social_provider_idx'),
                ],
            },
        ),
        migrations.CreateModel(
            name='SocialPendingMerge',
            fields=[
                ('id', models.BigAutoField(
                    auto_created=True, primary_key=True,
                    serialize=False, verbose_name='ID')),
                ('merge_token', models.CharField(
                    max_length=64, unique=True, verbose_name='マージトークン')),
                ('social_provider', models.CharField(
                    max_length=10, verbose_name='プロバイダー')),
                ('social_uid', models.CharField(
                    max_length=128, verbose_name='プロバイダーUID')),
                ('social_email', models.EmailField(
                    blank=True, verbose_name='ソーシャルEmail')),
                ('expires_at', models.DateTimeField(verbose_name='有効期限')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('existing_user', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='pending_merges',
                    to=settings.AUTH_USER_MODEL,
                    verbose_name='既存ユーザー')),
            ],
            options={
                'verbose_name': 'ソーシャルマージ保留',
                'verbose_name_plural': 'ソーシャルマージ保留',
            },
        ),
    ]
