import boto3
from datetime import datetime, timedelta

def get_service_from_usage(usage_type, tenant):
    """
    Helper to derive Service name since AWS API limits us to 2 GroupBy dimensions.
    """
    ut = usage_type.lower()
    if "tax" in ut or tenant == "Tax": return "Tax"
    if "boxusage" in ut: return "EC2 (Instance)"
    if "volumeusage" in ut or "iops" in ut: return "EC2 (EBS Storage)"
    if "natgateway" in ut: return "VPC (NAT Gateway)"
    if "datatransfer" in ut or "out-bytes" in ut: return "Data Transfer"
    if "s3-" in ut or "requests-" in ut: return "S3"
    if "lambda" in ut: return "Lambda"
    return "Other Services"

def lambda_handler(event, context):
    start_date = event.get('start_date')
    end_date = event.get('end_date')

    # If no dates are provided, default to yesterday
    if not start_date or not end_date:
        # Using UTC is best practice for AWS Cost Explorer which operates in UTC
        today = datetime.utcnow() 
        yesterday = today - timedelta(days=1)
        
        # Start date is inclusive (Yesterday)
        start_date = yesterday.strftime('%Y-%m-%d')
        # End date is exclusive (Today)
        end_date = today.strftime('%Y-%m-%d')

    ce = boto3.client('ce')

    # We group by TAG and USAGE_TYPE to get the most granular data
    response = ce.get_cost_and_usage(
        TimePeriod={'Start': start_date, 'End': end_date},
        Granularity='DAILY', # Changed to DAILY to support day-level querying
        Metrics=['UnblendedCost'],
        GroupBy=[
            {'Type': 'TAG', 'Key': 'Tenant'},
            {'Type': 'DIMENSION', 'Key': 'USAGE_TYPE'}
        ]
    )

    results = []
    for result in response['ResultsByTime']:
        # Changed variable name from month_label to date_label to reflect daily data
        date_label = result['TimePeriod']['Start'] 
        for group in result['Groups']:
            # 1. Process Tenant Tag
            tenant_key = group['Keys'][0] if group['Keys'][0] else ""
            tenant = tenant_key.split('$', 1)[1] if '$' in tenant_key else tenant_key
            
            # 2. Process Usage Detail
            usage_detail = group['Keys'][1] if len(group['Keys']) > 1 else "Unknown"
            
            # 3. Derive Service (The "Added" Column)
            service = get_service_from_usage(usage_detail, tenant)
            
            # 4. Handle Tax formatting
            if "Tax" in usage_detail:
                tenant = "Account-Level" if not tenant or tenant == "_NoTag" else tenant
                service = "Tax"

            cost_usd = float(group['Metrics']['UnblendedCost']['Amount'])
            cost_usd_str = f"{cost_usd:.2f}".replace('.', ',')

            if cost_usd > 0:
                results.append({
                    "Date": date_label, # Updated key name from 'Month' to 'Date'
                    "Tenant": tenant if tenant else "_NoTag",
                    "Service": service,
                    "Usage_Detail": usage_detail,
                    "Cost_USD": cost_usd_str,
                    "Raw_Cost": cost_usd
                })
    
    return results