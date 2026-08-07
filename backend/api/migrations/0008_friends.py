from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0007_habit_memo'),
    ]

    operations = [
        # PlayerProfile: friend_id, all_private
        migrations.AddField(
            model_name='playerprofile',
            name='friend_id',
            field=models.CharField(blank=True, default='', max_length=9, verbose_name='フレンドID'),
            preserve_default=False,
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='all_private',
            field=models.BooleanField(default=False, verbose_name='全習慣非公開'),
        ),
        migrations.AlterField(
            model_name='playerprofile',
            name='friend_id',
            field=models.CharField(blank=True, max_length=9, unique=True, verbose_name='フレンドID'),
        ),

        # Habit: is_public
        migrations.AddField(
            model_name='habit',
            name='is_public',
            field=models.BooleanField(default=True, verbose_name='フレンドに公開'),
        ),

        # Friendship model
        migrations.CreateModel(
            name='Friendship',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('status', models.CharField(
                    choices=[('pending', '申請中'), ('accepted', '承認済み')],
                    default='pending',
                    max_length=10,
                    verbose_name='状態',
                )),
                ('created_at', models.DateTimeField(auto_now_add=True, verbose_name='作成日時')),
                ('from_player', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='sent_friend_requests',
                    to='api.playerprofile',
                    verbose_name='申請者',
                )),
                ('to_player', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='received_friend_requests',
                    to='api.playerprofile',
                    verbose_name='受信者',
                )),
            ],
            options={
                'verbose_name':        'フレンド関係',
                'verbose_name_plural': 'フレンド関係',
                'unique_together':     {('from_player', 'to_player')},
            },
        ),

        # Message model
        migrations.CreateModel(
            name='Message',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('content', models.CharField(max_length=40, verbose_name='内容')),
                ('created_at', models.DateTimeField(auto_now_add=True, verbose_name='送信日時')),
                ('sender', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='sent_messages',
                    to='api.playerprofile',
                    verbose_name='送信者',
                )),
                ('receiver', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='received_messages',
                    to='api.playerprofile',
                    verbose_name='受信者',
                )),
            ],
            options={
                'verbose_name':        'メッセージ',
                'verbose_name_plural': 'メッセージ',
                'ordering':            ['created_at'],
            },
        ),
    ]
