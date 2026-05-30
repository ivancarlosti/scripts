import boto3
import json
from datetime import datetime
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    
    """
    Sample for JSON Input for n8n call:
    
    {
      "backblaze_key_id": "BACKBLAZEAPPKEY",
      "backblaze_key": "BACKBLAZESECRETKEY",
      "backblaze_endpoint": "s3.REGION.backblazeb2.com",
      "dest_bucket": "BACKBLAZEBUCKET",
      "exclude_buckets": ["temp-bucket", "logs"]
    }
    """
    
    # Extract parameters from the event
    backblaze_key_id = event.get('backblaze_key_id')
    backblaze_key = event.get('backblaze_key')
    backblaze_endpoint = event.get('backblaze_endpoint')
    dest_bucket = event.get('dest_bucket')
    exclude_buckets = event.get('exclude_buckets', [])
    
    # Validate required parameters
    if not backblaze_key_id or not backblaze_key or not backblaze_endpoint or not dest_bucket:
        raise ValueError("Missing required parameters: backblaze_key_id, backblaze_key, backblaze_endpoint, dest_bucket")
    
    logger.info(f"Starting backup to destination bucket: {dest_bucket}")
    
    s3_client = boto3.client('s3')
    
    # Backblaze B2 S3-compatible client
    b2_client = boto3.client(
        's3',
        endpoint_url=f"https://{backblaze_endpoint}",
        aws_access_key_id=backblaze_key_id,
        aws_secret_access_key=backblaze_key,
        region_name='us-west-004'
    )
    
    # Get list of all buckets, excluding if requested
    all_buckets_resp = s3_client.list_buckets()
    bucket_names = [b['Name'] for b in all_buckets_resp['Buckets'] if b['Name'] not in exclude_buckets]
    
    timestamp = datetime.utcnow().strftime('%Y-%m-%d_%H-%M-%S')
    
    total_copied = 0
    
    for bucket_name in bucket_names:
        logger.info(f"Backing up bucket: {bucket_name}")
        paginator = s3_client.get_paginator('list_objects_v2')
        page_iterator = paginator.paginate(Bucket=bucket_name)

        copied_in_bucket = 0

        for page in page_iterator:
            if 'Contents' not in page:
                logger.info(f"No objects found in bucket {bucket_name}")
                continue

            for obj in page['Contents']:
                key = obj['Key']
                source = {'Bucket': bucket_name, 'Key': key}
                dest_key = f"{bucket_name}/{timestamp}/{key}"
                try:
                    # Download the object content from source S3
                    obj_body = s3_client.get_object(Bucket=bucket_name, Key=key)['Body'].read()
                    # Upload to Backblaze B2 bucket
                    b2_client.put_object(
                        Bucket=dest_bucket,
                        Key=dest_key,
                        Body=obj_body,
                        Metadata={
                            'original-bucket': bucket_name,
                            'backup-timestamp': timestamp
                        }
                    )
                    copied_in_bucket += 1
                    total_copied += 1
                    if copied_in_bucket % 100 == 0:
                        logger.info(f"Copied {copied_in_bucket} objects from {bucket_name} so far")
                except Exception as e:
                    logger.error(f"Error copying object {key} from bucket {bucket_name}: {str(e)}")
                    continue

        logger.info(f"Completed bucket {bucket_name} backup: {copied_in_bucket} objects copied")

    logger.info(f"Backup completed. Total objects copied: {total_copied}")

    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': f'Backup completed for {len(bucket_names)} buckets to {dest_bucket}',
            'total_objects_copied': total_copied,
            'destination_bucket': dest_bucket
        })
    }
