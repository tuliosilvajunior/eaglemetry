# Range Drop over recorded history

The comparison the in-car panel makes live, made again over what is already
recorded: how many kilometres of promised range a readout spends per kilometre
actually driven. `1.000` is honest; above it, the readout was promising more
than the road could take.

```bash
# one car, from a snapshot pulled off it
python3 -m tool.telemetry_report pull dbpull/<name>.db
python3 -m tool.range_drop snapshot dbpull/<name>.db

# every vehicle in the cloud replica
python3 -m tool.range_drop cloud --by-vehicle

python3 -m unittest tool.range_drop.test_metric
```

## Two things to know before you read a number

**The deadband understates the drop.** `RANGE_REMAINING` is written on a
deadband, so the last sample of a trip can be minutes old and the readout can
have fallen further before the car stopped. The error this leaves is always in
the dashboard's favour, so the headline ratio is a floor. `--max-lag 60` keeps
only the trips whose last sample landed near the end; expect a *higher* ratio
from that subset, not a lower one.

**The fleet has no app line.** Pack capacity is a device setting the car keeps
in its own preferences and never uploads, so SOC cannot be turned into kWh for
a vehicle other than the one whose capacity you state. `cloud` therefore scores
the car's readout only. `snapshot` scores both, using `--capacity-kwh`.

## The cloud credential

`from_cloud` reads a connection URL from `.pgurl.pooler` (gitignored) and hands
it to `psql` through the environment, so the password never reaches an argument
list. The role in that file bypasses row-level security: this reads every
vehicle in the project, including other people's. That is the account owner's
call to make deliberately, which is why it is a separate subcommand and not a
flag on the snapshot one.
