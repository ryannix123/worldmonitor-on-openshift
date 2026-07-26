Subject: API token request — self-hosted conflict monitoring dashboard (personal/educational use)

Hello,

I would like to request an API access token for the UCDP Georeferenced Event
Dataset (GED).

**Who I am**
Ryan Nix — Senior Solutions Architect at Red Hat, based in Illinois, USA.

**What I am building**
A self-hosted deployment of World Monitor (https://github.com/koala73/worldmonitor),
an open-source situational-awareness dashboard, running on my own OpenShift
cluster. I rebuilt its container images on Red Hat UBI and deploy it privately.

**How UCDP data would be used**
The dashboard's armed-conflict layer reads UCDP GED to display georeferenced
conflict events on a world map alongside other public sources. Requests are
made by a scheduled background job (default cadence: every 6 hours), and the
results are cached locally in Redis rather than re-queried per page view, so
request volume against your API stays low.

**Scope of access**
This is a personal, non-commercial deployment. It is not a public service and
is not resold or redistributed. The primary audience is myself and my son, a
university student in a Naval ROTC program, who has an academic interest in
following global conflict data from open sources.

**Attribution**
UCDP is credited in the application's data-source listing, and I am happy to
follow any specific citation requirements you prefer for the GED dataset.

I am glad to provide further detail about the deployment or adjust request
cadence if that would help.

Thank you for your time and for maintaining this dataset.

Best regards,
Ryan Nix
ryan.nix@gmail.com
