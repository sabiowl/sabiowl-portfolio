from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0024_player_reminder_settings'),
    ]

    operations = [
        migrations.CreateModel(
            name='Gift',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name='ID')),
                ('diamonds', models.IntegerField(verbose_name='贈ったダイヤ数')),
                ('sent_at', models.DateTimeField(auto_now_add=True, verbose_name='送信日時')),
                ('sender', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='sent_gifts',
                    to='api.playerprofile',
                    verbose_name='送信者')),
                ('receiver', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='received_gifts',
                    to='api.playerprofile',
                    verbose_name='受信者')),
            ],
            options={'ordering': ['-sent_at']},
        ),
    ]
