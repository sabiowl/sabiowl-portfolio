from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('api', '0009_alter_checklistitem_id_alter_playeritem_id'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='user',
            field=models.OneToOneField(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.CASCADE,
                related_name='player_profile',
                to=settings.AUTH_USER_MODEL,
                verbose_name='ユーザー',
            ),
        ),
    ]
