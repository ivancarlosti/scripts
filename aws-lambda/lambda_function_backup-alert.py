import boto3
from datetime import datetime, timedelta
import json

def lambda_handler(event, context):
    client = boto3.client('backup')
    days = 1  # Set search day for alert return
    time_cutoff = datetime.utcnow() - timedelta(days=days)
    statuses = ['FAILED', 'EXPIRED']
    failed_or_expired_jobs = []

    for status in statuses:
        next_token = None
        while True:
            params = {
                'ByCreatedAfter': time_cutoff,
                'ByState': status,
                'MaxResults': 1000
            }
            if next_token:
                params['NextToken'] = next_token

            response = client.list_backup_jobs(**params)

            for job in response.get('BackupJobs', []):
                # Use DescribeBackupJob to pull additional information of backup jobs
                job_details = client.describe_backup_job(
                    BackupJobId=job.get('BackupJobId')
                )
                failed_or_expired_jobs.append({
                    'BackupJobId': job.get('BackupJobId'),
                    'ResourceArn': job.get('ResourceArn'),
                    'BackupVaultName': job.get('BackupVaultName'),
                    'CreatedAt': job.get('CreationDate').isoformat(),
                    'Status': job.get('State'),
                    'StatusMessage': job_details.get('StatusMessage'),
                    'CompletionDate': job.get('CompletionDate').isoformat() if job.get('CompletionDate') else None,
                    'BackupType': job_details.get('BackupType'),
                    'BytesTransferred': job_details.get('BytesTransferred'),
                    'IAMRoleArn': job_details.get('IamRoleArn')
                })

            next_token = response.get('NextToken')
            if not next_token:
                break

    return {
        'statusCode': 200,
        'body': json.dumps(failed_or_expired_jobs)
    }
