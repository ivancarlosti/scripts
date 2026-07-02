import boto3

# SKU mappings per region with new large instance types added
SKU_MAP = {
    'sa-east-1': {
        "t3a.medium": "AEC2T3AMEDSAE1",
        "t3a.micro": "AEC2T3AMICSAE1",
        "t3a.nano": "AEC2T3ANANSAE1",
        "t3a.small": "AEC2T3ASMASAE1",
        "t3a.large": "AEC2T3ALARSAE1",  # added
        "t4g.medium": "AEC2T4GMEDSAE1",
        "t4g.micro": "AEC2T4GMICSAE1",
        "t4g.nano": "AEC2T4GNANSAE1",
        "t4g.small": "AEC2T4GSMASAE1",
        "t4g.large": "AEC2T4GLARSAE1"   # added
    },
    'us-east-1': {
        "t3a.medium": "AEC2T3AMEDUSE1",
        "t3a.micro": "AEC2T3AMICUSE1",
        "t3a.nano": "AEC2T3ANANUSE1",
        "t3a.small": "AEC2T3ASMAUSE1",
        "t3a.large": "AEC2T3ALARUSE1",  # added
        "t4g.medium": "AEC2T4GMEDUSE1",
        "t4g.micro": "AEC2T4GMICUSE1",
        "t4g.nano": "AEC2T4GNANUSE1",
        "t4g.small": "AEC2T4GSMASUE1",
        "t4g.large": "AEC2T4GLARUSE1"   # added
    }
}

ROUTE53_SKU = "AROUTE53ZONE"

def lambda_handler(event, context):
    tenant_zone_count = {}
    tenant_zone_names = {}
    tenant_ec2_data = {}
    tenant_ec2_names = {}

    route53 = boto3.client('route53')

    # Route 53 processing
    hosted_zones = route53.list_hosted_zones()['HostedZones']
    for zone in hosted_zones:
        zone_id = zone['Id'].split('/')[-1]
        tags_response = route53.list_tags_for_resource(ResourceType='hostedzone', ResourceId=zone_id)
        tenant_tag = None
        for tag in tags_response.get('ResourceTagSet', {}).get('Tags', []):
            if tag['Key'] == 'Tenant':
                tenant_tag = tag['Value']
                break
        if not tenant_tag:
            tenant_tag = "_NoTag"
        tenant_zone_count[tenant_tag] = tenant_zone_count.get(tenant_tag, 0) + 1
        tenant_zone_names.setdefault(tenant_tag, []).append(zone['Name'].rstrip('.'))

    # EC2 processing for sa-east-1 and us-east-1 regions
    regions = ['sa-east-1', 'us-east-1']
    for region in regions:
        ec2 = boto3.client('ec2', region_name=region)
        paginator = ec2.get_paginator('describe_instances')
        for page in paginator.paginate(Filters=[{'Name': 'tag-key', 'Values': ['Tenant']}]):
            for reservation in page['Reservations']:
                for instance in reservation['Instances']:
                    tenant_tag = None
                    instance_name = None
                    for tag in instance.get('Tags', []):
                        if tag['Key'] == 'Tenant':
                            tenant_tag = tag['Value']
                        if tag['Key'] == 'Name':
                            instance_name = tag['Value']
                    if not tenant_tag:
                        tenant_tag = "_NoTag"
                    if not instance_name:
                        instance_name = instance['InstanceId']
                    instance_type = instance.get('InstanceType', 'UNIDENTIFIED')
                    sku = SKU_MAP.get(region, {}).get(instance_type, "UNIDENTIFIED")
                    key = (tenant_tag, sku)
                    tenant_ec2_data[key] = tenant_ec2_data.get(key, 0) + 1
                    tenant_ec2_names.setdefault(key, []).append(instance_name)

    report = []
    for tenant, count in tenant_zone_count.items():
        names = tenant_zone_names.get(tenant, [])
        report.append({
            "Tenant": tenant,
            "AWS_product": "Route 53",
            "Asset Count": count,
            "SKU": ROUTE53_SKU,
            "AWS_resources": ", ".join(names)
        })

    for (tenant, sku), count in tenant_ec2_data.items():
        names = tenant_ec2_names.get((tenant, sku), [])
        report.append({
            "Tenant": tenant,
            "AWS_product": "EC2",
            "Asset Count": count,
            "SKU": sku,
            "AWS_resources": ", ".join(names)
        })

    return report
