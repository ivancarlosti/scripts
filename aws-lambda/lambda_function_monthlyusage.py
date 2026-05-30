import boto3
from datetime import datetime, timedelta

def lambda_handler(event, context):
    start_date = event.get('start_date')
    end_date = event.get('end_date')

    if not start_date or not end_date:
        now = datetime.now()
        first_day_this_month = datetime(now.year, now.month, 1)
        first_day_last_month = (first_day_this_month - timedelta(days=1)).replace(day=1)
        first_day_this_month_str = first_day_this_month.strftime('%Y-%m-%d')
        first_day_last_month_str = first_day_last_month.strftime('%Y-%m-%d')
        start_date = first_day_last_month_str
        end_date = first_day_this_month_str  # Set to first day of current month (exclusive)

    ce = boto3.client('ce')

    response = ce.get_cost_and_usage(
        TimePeriod={'Start': start_date, 'End': end_date},
        Granularity='MONTHLY',
        Metrics=['UnblendedCost'],
        GroupBy=[
            {'Type': 'TAG', 'Key': 'Tenant'},
            {'Type': 'DIMENSION', 'Key': 'SERVICE'}
        ]
    )

    results = []
    for result in response['ResultsByTime']:
        for group in result['Groups']:
            tenant_key = group['Keys'][0] if group['Keys'][0] else ""
            tenant = tenant_key.split('$', 1)[1] if '$' in tenant_key else tenant_key
            if not tenant:
                tenant = "_NoTag"
            service = group['Keys'][1] if len(group['Keys']) > 1 else "Unknown"
            cost_usd = float(group['Metrics']['UnblendedCost']['Amount'])
            cost_usd_str = f"{cost_usd:.2f}".replace('.', ',')
            results.append({
                "Tenant": tenant,
                "Service": service,
                "Cost (USD)": cost_usd_str
            })
    return results
