from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0059_drop_passkey_push_models'),
    ]

    operations = [
        # FK 順に削除（LanternDelivery は Lantern を参照しないが念のため先）
        migrations.DeleteModel(name='LanternDelivery'),
        migrations.DeleteModel(name='Lantern'),
    ]
