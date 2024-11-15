#!/bin/bash

set -e

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/../../set-config.sh"

function gen_random_pswd() {
    aws secretsmanager --output json get-random-password --exclude-characters "\"'/\\[]=:,{}@&" \
        --password-length $1 | jq -r '.RandomPassword'
}

RESOURCES_STACK_NAME="${CLUSTER_NAME}-resources"
HEALTHCHECKS_STACK_NAME="${CLUSTER_NAME}-${AWS_DEFAULT_REGION}-healthchecks"
RESOURCES_STACK_CONFIG_FILE="$CLUSTER_HOME/aws-infra/resources/resources.yaml"
HEALTHCHECKS_STACK_CONFIG_FILE="$CLUSTER_HOME/aws-infra/resources/healthchecks.yaml"

resources_stack=$(aws cloudformation describe-stacks --stack-name $RESOURCES_STACK_NAME | jq '.Stacks[0]')
if [ -z "$resources_stack" ] || [ "$resources_stack" == "null" ]; then
    eks_stack=$(aws cloudformation describe-stacks --stack-name eksctl-${CLUSTER_NAME}-cluster | jq '.Stacks[0]')
    vpc_id=$(echo $eks_stack | jq -r '.Outputs[] | select(.OutputKey=="VPC").OutputValue')
    private_subnet_ids=$(echo $eks_stack | jq -r '.Outputs[] | select(.OutputKey=="SubnetsPrivate").OutputValue')
    private_route_table_ids=$(aws ec2 describe-route-tables --region $AWS_DEFAULT_REGION --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Name,Values=eksctl-${CLUSTER_NAME}-cluster/Private*" | jq -r '.RouteTables[].RouteTableId' | paste -s -d, -)
    cluster_security_group=$(echo $eks_stack | jq -r '.Outputs[] | select(.OutputKey=="ClusterSecurityGroupId").OutputValue')

    aws cloudformation create-stack --stack-name $RESOURCES_STACK_NAME --capabilities CAPABILITY_NAMED_IAM \
        --template-body file://$RESOURCES_STACK_CONFIG_FILE --parameters \
        ParameterKey=VpcId,ParameterValue=$vpc_id \
        ParameterKey=PrivateSubnetIds,ParameterValue=${private_subnet_ids//,/\\,} \
        ParameterKey=PrivateRouteTableIds,ParameterValue=${private_route_table_ids//,/\\,} \
        ParameterKey=ClusterNodesSecurityGroupId,ParameterValue=$cluster_security_group \
        ParameterKey=BackupRegion,ParameterValue=$AWS_BACKUP_REGION \
        ParameterKey=BackupRegionBucketNamePrefix,ParameterValue=$S3_BACKUP_REGION_BUCKET_NAME_PREFIX \
        ParameterKey=DeliveryInstanceCount,ParameterValue=$DELIVERY_INSTANCE_COUNT \
        ParameterKey=CloudWatchAlarmsEnabled,ParameterValue=$ENABLE_CLOUDWATCH_ALARMS \
        ParameterKey=AlarmsEmailAddress,ParameterValue=$ALARMS_EMAIL_ADDRESS \
        ParameterKey=AlarmsSlackChannelHookUrl,ParameterValue=$ALARMS_SLACK_CHANNEL_HOOK_URL \
        ParameterKey=OpenSearchSingleNodeCluster,ParameterValue=$OPEN_SEARCH_SINGLE_NODE_CLUSTER

    cecho "Waiting for resources stack to be created..." "info"

    aws cloudformation wait stack-create-complete --stack-name $RESOURCES_STACK_NAME
else
    cecho "Resources stack $RESOURCES_STACK_NAME already exists" "info"
fi

healthchecks_stack=$(aws cloudformation describe-stacks --region 'us-east-1' --stack-name $HEALTHCHECKS_STACK_NAME | jq '.Stacks[0]')
if [ -z "$healthchecks_stack" ] || [ "$healthchecks_stack" == "null" ]; then
    if [ "$AWS_DEFAULT_REGION" == "us-east-1" ]; then
        aws cloudformation create-stack --stack-name $HEALTHCHECKS_STACK_NAME --capabilities CAPABILITY_NAMED_IAM \
            --template-body file://$HEALTHCHECKS_STACK_CONFIG_FILE --parameters \
            ParameterKey=AuthoringHealthcheckHostname,ParameterValue=$AUTHORING_DOMAIN_NAME \
            ParameterKey=AuthoringHealthcheckPath,ParameterValue=${AUTHORING_HEALTHCHECK_PATH/token=/"token=$CRAFTER_MANAGEMENT_TOKEN"} \
            ParameterKey=DeliveryHealthcheckHostname,ParameterValue=$DELIVERY_DOMAIN_NAME \
            ParameterKey=DeliveryHealthcheckPath,ParameterValue=${DELIVERY_HEALTHCHECK_PATH/token=/"token=$CRAFTER_MANAGEMENT_TOKEN"} \
            ParameterKey=AlarmsSlackChannelHookUrl,ParameterValue=$ALARMS_SLACK_CHANNEL_HOOK_URL \
            ParameterKey=PagerDutyIntegrationUrl,ParameterValue=$PAGER_DUTY_INTEGRATION_URL

    else
        aws cloudformation create-stack --region 'us-east-1' --stack-name $HEALTHCHECKS_STACK_NAME \
            --capabilities CAPABILITY_NAMED_IAM --template-body file://$HEALTHCHECKS_STACK_CONFIG_FILE --parameters \
            ParameterKey=AuthoringHealthcheckHostname,ParameterValue=$AUTHORING_DOMAIN_NAME \
            ParameterKey=AuthoringHealthcheckPath,ParameterValue=${AUTHORING_HEALTHCHECK_PATH/token=/"token=$CRAFTER_MANAGEMENT_TOKEN"} \
            ParameterKey=DeliveryHealthcheckHostname,ParameterValue=$DELIVERY_DOMAIN_NAME \
            ParameterKey=DeliveryHealthcheckPath,ParameterValue=${DELIVERY_HEALTHCHECK_PATH/token=/"token=$CRAFTER_MANAGEMENT_TOKEN"} \
            ParameterKey=AlarmsSlackChannelHookUrl,ParameterValue=$ALARMS_SLACK_CHANNEL_HOOK_URL \
            ParameterKey=PagerDutyIntegrationUrl,ParameterValue=$PAGER_DUTY_INTEGRATION_URL
    fi

    cecho "Waiting for resources stack to be created..." "info"
else
    cecho "Resources stack $HEALTHCHECKS_STACK_NAME already exists" "info"
fi