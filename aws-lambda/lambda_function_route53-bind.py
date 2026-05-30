import boto3
import datetime

def generate_bind_zone_file(domain_name, records):
    """
    Generates a simplified BIND zone file as a string,
    using the real SOA and NS records from the hosted zone.
    """

    # Find the SOA record for the domain
    soa_record = next(
        (r for r in records if r['Type'] == 'SOA' and r['Name'].rstrip('.') == domain_name),
        None
    )
    if not soa_record:
        raise ValueError(f"SOA record not found for domain {domain_name}")

    # Find the NS records for the domain
    ns_records = [
        r for r in records if r['Type'] == 'NS' and r['Name'].rstrip('.') == domain_name
    ]
    if not ns_records:
        raise ValueError(f"NS records not found for domain {domain_name}")

    output = []
    output.append(f"$TTL {soa_record.get('TTL', 300)}")

    # Build SOA record using the real fields
    soa_value = soa_record['ResourceRecords'][0]['Value']
    output.append(f"@  IN  SOA {soa_value}")

    # Add NS records
    for ns_record in ns_records:
        for rr in ns_record.get('ResourceRecords', []):
            output.append(f"@  IN  NS  {rr['Value']}")

    output.append("")

    # Add other records (except SOA and NS)
    for record in records:
        record_name = record['Name'].rstrip('.')
        record_type = record['Type']
        ttl = record.get('TTL', 300)
        values = record.get('ResourceRecords', [])

        if record_type in ['SOA', 'NS'] and record_name == domain_name:
            continue  # Already handled

        for val in values:
            val_str = val['Value']
            # Use '@' for root domain
            name_display = '@' if record_name == domain_name else record_name
            output.append(f"{name_display} {ttl} IN {record_type} {val_str}")

    return "\n".join(output)


def lambda_handler(event, context):
    client = boto3.client('route53')
    response = client.list_hosted_zones()
    zones = response['HostedZones']

    output = []

    for zone in zones:
        zone_id = zone['Id'].split("/")[-1]
        domain_name = zone['Name'].rstrip('.')

        records_response = client.list_resource_record_sets(HostedZoneId=zone_id)
        records = records_response['ResourceRecordSets']

        # Generate BIND zone file for the domain
        bind_file = generate_bind_zone_file(domain_name, records)

        output.append({
            "domain": domain_name,
            "bind_file": bind_file
        })

    return {
        "statusCode": 200,
        "zones": output
    }
