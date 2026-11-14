"""ACCS AWS architecture, drawn with the official AWS Architecture Icons.

Rebuild diagrams/accs-architecture.png (see README, Diagrams):

    podman run --rm -v "$PWD/diagrams:/work:Z" -w /work python:3.12-slim sh -c \
      "apt-get update -qq && apt-get install -y -qq graphviz >/dev/null && pip install -q diagrams && python accs_architecture.py"
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import Lambda
from diagrams.aws.database import Dynamodb
from diagrams.aws.engagement import SimpleEmailServiceSes
from diagrams.aws.management import Cloudwatch
from diagrams.aws.network import APIGateway, CloudFront, Route53
from diagrams.aws.security import CertificateManager, IAMRole
from diagrams.aws.storage import S3
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.client import Users

graph_attr = {"pad": "0.4", "nodesep": "0.5", "ranksep": "0.9", "fontsize": "22", "bgcolor": "white", "splines": "spline"}

with Diagram(
    "ACCS on AWS (accs-dev / accs-prod)",
    filename="accs-architecture",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
):
    users = Users("Browser")
    ci = GithubActions("GitHub Actions\n(OIDC, no AWS keys)")

    cert = CertificateManager("ACM certificate\n(us-east-1)")

    with Cluster("AWS account meetingatten · ap-southeast-1"):
        dns = Route53("Route 53\naccess-ccs.com")

        with Cluster("Static sites (static-site.yaml)"):
            cdn = CloudFront("CloudFront x4\nlanding, portal,\nMeeting At 10, design system")
            sites = S3("S3 site buckets\nprivate, OAC")

        with Cluster("API (api.yaml)"):
            api = APIGateway("HTTP API")
            fn = Lambda("Lambda\nNode 22 arm64\naccs-backend")
            logs = Cloudwatch("CloudWatch Logs\n14 days")
            auth = S3("Auth store bucket")

        with Cluster("Database (database.yaml)"):
            ddb = Dynamodb("DynamoDB\n12 ccs_* tables")

        with Cluster("Email (accs-email)"):
            ses = SimpleEmailServiceSes("Amazon SES\nno-reply@access-ccs.com")

        roles = IAMRole("Deploy roles")

    users >> Edge(label="DNS") >> dns
    users >> Edge(label="HTTPS") >> cdn >> Edge(label="OAC signed") >> sites
    cert >> Edge(style="dashed", label="TLS") >> cdn
    users >> Edge(label="HTTPS /api/*") >> api >> fn
    fn >> ddb
    fn >> auth
    fn >> Edge(style="dashed") >> logs
    fn >> Edge(label="reset codes, invites,\nnew concerns") >> ses
    ci >> Edge(label="assume role") >> roles
    roles >> Edge(style="dashed") >> [fn, sites]
