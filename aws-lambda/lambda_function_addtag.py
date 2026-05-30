import boto3
import re

def get_tag(tags, key):
    for tag in tags:
        if tag['Key'] == key:
            return tag['Value']
    return None

def add_output(output, resource_type, resource_id, tenant_value, status, **kwargs):
    entry = {
        "ResourceType": resource_type,
        "ResourceId": resource_id,
        "Tenant": tenant_value,
        "Status": status
    }
    entry.update(kwargs)
    output.append(entry)

def lambda_handler(event, context):
    ec2 = boto3.client('ec2')
    kms = boto3.client('kms', region_name='us-east-1')
    route53 = boto3.client('route53')
    output = []

    # 1. AMIs
    images = ec2.describe_images(Owners=['self'])['Images']
    for image in images:
        already_tagged = any(tag['Key'] == 'Tenant' for tag in image.get('Tags', []))
        name = image.get('Name', '')
        desc = image.get('Description', '')
        match = re.search(r'i-[0-9a-f]+', name) or re.search(r'i-[0-9a-f]+', desc)
        instance_id = match.group(0) if match else None
        tenant = None

        if instance_id:
            try:
                reservations = ec2.describe_instances(InstanceIds=[instance_id])['Reservations']
                if reservations and reservations[0]['Instances']:
                    tags = reservations[0]['Instances'][0].get('Tags', [])
                    tenant = get_tag(tags, 'Tenant')
            except Exception as e:
                add_output(output, "AMI", image['ImageId'], tenant or "TagNotExists", f"InstanceDescribeError: {str(e)}", SourceID=instance_id)
                continue

        if already_tagged:
            add_output(output, "AMI", image['ImageId'], tenant or "TagNotExists", "AlreadyTagged", SourceID=instance_id)
            continue

        if not instance_id:
            add_output(output, "AMI", image['ImageId'], "TagNotExists", "NoInstanceIdInName")
            continue

        if tenant:
            try:
                ec2.create_tags(Resources=[image['ImageId']], Tags=[{'Key': 'Tenant', 'Value': tenant}])
                add_output(output, "AMI", image['ImageId'], tenant, "TagAdded", SourceID=instance_id)
            except Exception as e:
                add_output(output, "AMI", image['ImageId'], tenant, f"TagError: {str(e)}", SourceID=instance_id)
        else:
            add_output(output, "AMI", image['ImageId'], "TagNotExists", "NoTenantTagOnInstance", SourceID=instance_id)

    # 2. Volumes EBS
    volumes = ec2.describe_volumes()['Volumes']
    for vol in volumes:
        already_tagged = any(tag['Key'] == 'Tenant' for tag in vol.get('Tags', []))
        attachments = vol.get('Attachments', [])
        instance_id = attachments[0]['InstanceId'] if attachments and attachments[0].get('InstanceId') else None
        tenant = None

        # Try to get Tenant tag from AMI if attached to an instance with an AMI
        if instance_id:
            # Try to get AMI from instance
            try:
                reservations = ec2.describe_instances(InstanceIds=[instance_id])['Reservations']
                if reservations and reservations[0]['Instances']:
                    instance = reservations[0]['Instances'][0]
                    ami_id = instance.get('ImageId')
                    if ami_id:
                        # Get the Tenant tag from the AMI if it exists
                        images = ec2.describe_images(ImageIds=[ami_id])['Images']
                        if images:
                            tenant = get_tag(images[0].get('Tags', []), 'Tenant')
                    # Fallback: get Tenant tag from instance itself if AMI doesn't have it
                    if not tenant:
                        tenant = get_tag(instance.get('Tags', []), 'Tenant')
            except Exception as e:
                add_output(output, "Volume", vol['VolumeId'], tenant or "TagNotExists", f"InstanceDescribeError: {str(e)}", SourceID=instance_id)
                continue

        if already_tagged:
            add_output(output, "Volume", vol['VolumeId'], tenant or "TagNotExists", "AlreadyTagged", SourceID=instance_id)
            continue

        if not instance_id:
            add_output(output, "Volume", vol['VolumeId'], "TagNotExists", "NoInstanceAttachment")
            continue

        if tenant:
            try:
                ec2.create_tags(Resources=[vol['VolumeId']], Tags=[{'Key': 'Tenant', 'Value': tenant}])
                add_output(output, "Volume", vol['VolumeId'], tenant, "TagAdded", SourceID=instance_id)
            except Exception as e:
                add_output(output, "Volume", vol['VolumeId'], tenant, f"TagError: {str(e)}", SourceID=instance_id)
        else:
            add_output(output, "Volume", vol['VolumeId'], "TagNotExists", "NoTenantTagOnInstanceOrAMI", SourceID=instance_id)

    # 3. Snapshots EBS
    snapshots = ec2.describe_snapshots(OwnerIds=['self'])['Snapshots']
    for snap in snapshots:
        already_tagged = any(tag['Key'] == 'Tenant' for tag in snap.get('Tags', []))
        volume_id = snap.get('VolumeId')
        tenant = None

        if volume_id:
            try:
                volumes = ec2.describe_volumes(VolumeIds=[volume_id])['Volumes']
                if volumes:
                    tenant = get_tag(volumes[0].get('Tags', []), 'Tenant')
            except Exception as e:
                if 'InvalidVolume.NotFound' in str(e):
                    add_output(output, "Snapshot", snap['SnapshotId'], tenant or "TagNotExists", "NoVolumeIDFound", SourceID=volume_id)
                else:
                    add_output(output, "Snapshot", snap['SnapshotId'], tenant or "TagNotExists", f"VolumeDescribeError: {str(e)}", SourceID=volume_id)
                continue

        if already_tagged:
            add_output(output, "Snapshot", snap['SnapshotId'], tenant or "TagNotExists", "AlreadyTagged", SourceID=volume_id)
            continue

        if not volume_id:
            add_output(output, "Snapshot", snap['SnapshotId'], "TagNotExists", "NoVolumeId")
            continue

        if tenant:
            try:
                ec2.create_tags(Resources=[snap['SnapshotId']], Tags=[{'Key': 'Tenant', 'Value': tenant}])
                add_output(output, "Snapshot", snap['SnapshotId'], tenant, "TagAdded", SourceID=volume_id)
            except Exception as e:
                add_output(output, "Snapshot", snap['SnapshotId'], tenant, f"TagError: {str(e)}", SourceID=volume_id)
        else:
            add_output(output, "Snapshot", snap['SnapshotId'], "TagNotExists", "NoTenantTagOnVolume", SourceID=volume_id)

    # 4. Network Interfaces (ENIs)
    enis = ec2.describe_network_interfaces()['NetworkInterfaces']
    for eni in enis:
        already_tagged = any(tag['Key'] == 'Tenant' for tag in eni.get('TagSet', []))
        attachment = eni.get('Attachment', {})
        instance_id = attachment.get('InstanceId')
        tenant = None

        if instance_id:
            try:
                reservations = ec2.describe_instances(InstanceIds=[instance_id])['Reservations']
                if reservations and reservations[0]['Instances']:
                    tags = reservations[0]['Instances'][0].get('Tags', [])
                    tenant = get_tag(tags, 'Tenant')
            except Exception as e:
                add_output(output, "NetworkInterface", eni['NetworkInterfaceId'], tenant or "TagNotExists", f"InstanceDescribeError: {str(e)}", SourceID=instance_id)
                continue

        if already_tagged:
            add_output(output, "NetworkInterface", eni['NetworkInterfaceId'], tenant or "TagNotExists", "AlreadyTagged", SourceID=instance_id)
            continue

        if not instance_id:
            add_output(output, "NetworkInterface", eni['NetworkInterfaceId'], "TagNotExists", "NoInstanceAttachment")
            continue

        if tenant:
            try:
                ec2.create_tags(Resources=[eni['NetworkInterfaceId']], Tags=[{'Key': 'Tenant', 'Value': tenant}])
                add_output(output, "NetworkInterface", eni['NetworkInterfaceId'], tenant, "TagAdded", SourceID=instance_id)
            except Exception as e:
                add_output(output, "NetworkInterface", eni['NetworkInterfaceId'], tenant, f"TagError: {str(e)}", SourceID=instance_id)
        else:
            add_output(output, "NetworkInterface", eni['NetworkInterfaceId'], "TagNotExists", "NoTenantTagOnInstance", SourceID=instance_id)

    # 5. Elastic IPs (EIPs)
    addresses = ec2.describe_addresses()['Addresses']
    for addr in addresses:
        allocation_id = addr.get('AllocationId')
        instance_id = addr.get('InstanceId')
        tags = addr.get('Tags', [])
        already_tagged = any(tag['Key'] == 'Tenant' for tag in tags)
        tenant = None

        if instance_id:
            try:
                reservations = ec2.describe_instances(InstanceIds=[instance_id])['Reservations']
                if reservations and reservations[0]['Instances']:
                    instance_tags = reservations[0]['Instances'][0].get('Tags', [])
                    tenant = get_tag(instance_tags, 'Tenant')
            except Exception as e:
                add_output(output, "EIP", allocation_id, tenant or "TagNotExists", f"InstanceDescribeError: {str(e)}", SourceID=instance_id)
                continue

        if already_tagged:
            add_output(output, "EIP", allocation_id, tenant or "TagNotExists", "AlreadyTagged", SourceID=instance_id)
            continue

        if not instance_id:
            add_output(output, "EIP", allocation_id, "TagNotExists", "NoInstanceAttachment")
            continue

        if tenant:
            try:
                ec2.create_tags(Resources=[allocation_id], Tags=[{'Key': 'Tenant', 'Value': tenant}])
                add_output(output, "EIP", allocation_id, tenant, "TagAdded", SourceID=instance_id)
            except Exception as e:
                add_output(output, "EIP", allocation_id, tenant, f"TagError: {str(e)}", SourceID=instance_id)
        else:
            add_output(output, "EIP", allocation_id, "TagNotExists", "NoTenantTagOnInstance", SourceID=instance_id)

    # 6. KMS: Tag customer-managed keys with alias name as Tenant (us-east-1)
    paginator = kms.get_paginator('list_aliases')
    for page in paginator.paginate():
        for alias in page['Aliases']:
            alias_name = alias.get('AliasName', '')
            key_id = alias.get('TargetKeyId')
            if alias_name.startswith('alias/aws/') or not key_id:
                continue
            # FIX: Remove 'alias/' prefix for the tag value
            tenant_value = alias_name[len('alias/'):] if alias_name.startswith('alias/') else alias_name
            try:
                tags_resp = kms.list_resource_tags(KeyId=key_id)
                existing_tenant = next((t['TagValue'] for t in tags_resp.get('Tags', []) if t['TagKey'] == 'Tenant'), None)
                if existing_tenant == tenant_value:
                    add_output(output, "KMS", key_id, tenant_value, "AlreadyTagged")
                    continue
                kms.tag_resource(
                    KeyId=key_id,
                    Tags=[{'TagKey': 'Tenant', 'TagValue': tenant_value}]
                )
                add_output(output, "KMS", key_id, tenant_value, "TagAdded")
            except Exception as e:
                add_output(output, "KMS", key_id, tenant_value, f"TagError: {str(e)}")

    # 7. Route 53: Tag hosted zones with description as Tenant (only if needed)
    hosted_zones = route53.list_hosted_zones()['HostedZones']
    for zone in hosted_zones:
        zone_id = zone['Id'].split('/')[-1]
        description = zone.get('Config', {}).get('Comment', '')
        tenant_value = description
        if description:
            try:
                tags_resp = route53.list_tags_for_resource(ResourceType='hostedzone', ResourceId=zone_id)
                existing_tenant = next((t['Value'] for t in tags_resp.get('ResourceTagSet', {}).get('Tags', []) if t['Key'] == 'Tenant'), None)
                if existing_tenant == tenant_value:
                    add_output(output, "Route53HostedZone", zone_id, tenant_value, "AlreadyTagged")
                    continue
                route53.change_tags_for_resource(
                    ResourceType='hostedzone',
                    ResourceId=zone_id,
                    AddTags=[{'Key': 'Tenant', 'Value': tenant_value}]
                )
                add_output(output, "Route53HostedZone", zone_id, tenant_value, "TagAdded")
            except Exception as e:
                add_output(output, "Route53HostedZone", zone_id, tenant_value, f"TagError: {str(e)}")
        else:
            add_output(output, "Route53HostedZone", zone_id, "", "NoDescriptionNoTag")

    return output
