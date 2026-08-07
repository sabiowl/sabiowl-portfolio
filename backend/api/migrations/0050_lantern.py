from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0049_timelineevent_external_calendar'),
    ]

    operations = [
        migrations.CreateModel(
            name='Lantern',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True)),
                ('granted_date',      models.DateField()),
                ('total_count',       models.IntegerField(default=0)),
                ('self_count',        models.IntegerField(default=0)),
                ('anon_count',        models.IntegerField(default=0)),
                ('assigned_at',       models.DateTimeField(null=True, blank=True)),
                ('boost_consumed_at', models.DateTimeField(null=True, blank=True)),
                ('owner', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='lanterns',
                    to='api.playerprofile',
                )),
            ],
            options={
                'unique_together': {('owner', 'granted_date')},
            },
        ),
        migrations.CreateModel(
            name='LanternDelivery',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True)),
                ('sender_category',   models.CharField(blank=True, max_length=20)),
                ('delivered_at',      models.DateTimeField(auto_now_add=True)),
                ('received_at',       models.DateTimeField(null=True, blank=True)),
                ('boost_consumed_at', models.DateTimeField(null=True, blank=True)),
                ('recipient', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='lantern_deliveries',
                    to='api.playerprofile',
                )),
            ],
        ),
    ]
