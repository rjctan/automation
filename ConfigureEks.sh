#!/bin/bash -xv

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output=text)
AMX_PPL_ENV=$1
AMX_PPL_CLUSTER_EKS=$2
AMX_APP_PREFIX=$3
AMX_PPL_NAMESPACE=$4
AMX_PPL_VPC_ID=$5
AMX_PPL_ECR_REPO=$6
AWS_REGION=$7
EKS_DEPLOYER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${AMX_PPL_CLUSTER_EKS}-iam-rol-eks-deployer"
EKS_ROLE_KUBECTL_ARN="arn:aws:iam::${ACCOUNT_ID}:role/AMX-PPL-CB-EKS-KUBECTL-${ACCOUNT_ID}-${AWS_REGION}"
EKS_ROLE_BACKEND_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${AMX_PPL_CLUSTER_EKS}-${ACCOUNT_ID}-${AWS_REGION}"


CREDENTIALS=$(aws sts assume-role --role-arn ${EKS_ROLE_KUBECTL_ARN} --role-session-name amx-ppl-cc-admin)
export AWS_ACCESS_KEY_ID="$(echo ${CREDENTIALS} | jq -r '.Credentials.AccessKeyId')"
export AWS_SECRET_ACCESS_KEY="$(echo ${CREDENTIALS} | jq -r '.Credentials.SecretAccessKey')"
export AWS_SESSION_TOKEN=$(echo "${CREDENTIALS}" | jq -r '.Credentials.SessionToken')

aws eks update-kubeconfig            \
  --name ${AMX_PPL_CLUSTER_EKS}        \
  --role-arn ${EKS_DEPLOYER_ROLE_ARN} \
  --region ${AWS_REGION}

EksCheckRoleBackend=$(kubectl get cm aws-auth -n kube-system -o yaml | grep rolearn | grep ${AMX_PPL_CLUSTER_EKS}-${ACCOUNT_ID}-${AWS_REGION})
if [ "${EksCheckRoleBackend}" == "" ]
then
  ROLE="    - groups:\n      - system:masters\n      rolearn: ${EKS_ROLE_BACKEND_ARN}\n      username: codebuild-eks"
  kubectl get -n kube-system configmap/aws-auth -o yaml | awk "/mapRoles: \|/{print;print \"${ROLE}\";next}1" > /tmp/aws-auth-patch-backend.yml
  kubectl patch configmap/aws-auth -n kube-system --patch "$(cat /tmp/aws-auth-patch-backend.yml)"
fi
EksCheckRoleKubectl=$(kubectl get cm aws-auth -n kube-system -o yaml | grep rolearn | grep ${EKS_ROLE_KUBECTL_ARN})
if [ "${EksCheckRoleKubectl}" == "" ]
then
  ROLE="    - groups:\n      - system:masters\n      rolearn: ${EKS_ROLE_KUBECTL_ARN}\n      username: codebuild-kubectl"
  kubectl get -n kube-system configmap/aws-auth -o yaml | awk "/mapRoles: \|/{print;print \"${ROLE}\";next}1" > /tmp/aws-auth-patch-backend.yml
  kubectl patch configmap/aws-auth -n kube-system --patch "$(cat /tmp/aws-auth-patch-backend.yml)"
fi

###############################
### Install AWS Load Controller
###############################
helm repo add eks https://aws.github.io/eks-charts
helm repo update
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller//crds?ref=master"
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.5/docs/install/iam_policy.json

AWSLoadBalancerControllerPolicy=$(aws iam get-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy --output text 2> /dev/null | grep POLICY | awk '{print $2}')
if [ "${AWSLoadBalancerControllerPolicy}" == "" ]
then
  aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy.json
fi
rm -f iam_policy.json

ServiceAccountAWSALbController=$(kubectl get serviceaccounts aws-load-balancer-controller -n kube-system 2> /dev/null | grep -v "^NAME" | awk '{print $1}')
if [ "${ServiceAccountAWSALbController}" == "" ]
then
  eksctl create iamserviceaccount \
    --cluster ${AMX_PPL_CLUSTER_EKS} \
    --namespace kube-system \
    --name aws-load-balancer-controller \
    --attach-policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
    --override-existing-serviceaccounts \
    --region ${AWS_REGION} --approve
fi

AWSLoadBalancerControllerDeployment=$(kubectl get deployment aws-load-balancer-controller -n kube-system 2> /dev/null | grep -v "^NAME" | awk '{print $1}')
if [ "${AWSLoadBalancerControllerDeployment}" == "" ]
then
  helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
    --set clusterName=${AMX_PPL_CLUSTER_EKS} \
    --set region=${AWS_REGION} \
    --set vpcId=${AMX_PPL_VPC_ID} \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set image.repository=${AMX_PPL_ECR_REPO}/amazon/aws-load-balancer-controller
fi

################
### Install Otel
################
ContainerInsightsFargateProfile=$(aws eks list-fargate-profiles --cluster-name ${AMX_PPL_CLUSTER_EKS} --output text --region ${AWS_REGION} | grep fargate-container-insights)
if [ "${ContainerInsightsFargateProfile}" == "" ]
then
  eksctl create fargateprofile           \
    --cluster ${AMX_PPL_CLUSTER_EKS}        \
    --name fargate-container-insights      \
    --namespace fargate-container-insights  \
    --region ${AWS_REGION}
fi

ServiceAccountFargateInsights=$(kubectl get serviceaccounts -n fargate-container-insights adot-collector 2> /dev/null | grep -v "^NAME" | awk '{print $1}')
if [ "${ServiceAccountFargateInsights}" == "" ]
then
  eksctl create iamserviceaccount \
    --cluster ${AMX_PPL_CLUSTER_EKS} \
    --region ${AWS_REGION} \
    --namespace fargate-container-insights \
    --name adot-collector \
    --role-name EKS-Fargate-ADOT-ServiceAccount-Role \
    --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
    --approve
fi
curl https://raw.githubusercontent.com/aws-observability/aws-otel-collector/main/deployment-template/eks/otel-fargate-container-insights.yaml | sed "s/YOUR-EKS-CLUSTER-NAME/'${AMX_PPL_CLUSTER_EKS}'/" | kubectl apply -f -

################################
### CloudWatch Log configuration
################################
curl -o permissions.json https://raw.githubusercontent.com/aws-samples/amazon-eks-fluent-logging-examples/mainline/examples/fargate/cloudwatchlogs/permissions.json
NameBackendLogGroup="${AMX_PPL_CLUSTER_EKS}-backend"
sed -i.bk "s/PLACEHOLDER_LOGGROUPNAME/${NameBackendLogGroup}/g" manifests/aws-logging-cloudwatch-configmap.yaml
sed -i.bk "s/PLACEHOLDER_LOGGROUPPREFIX/k8-logs/g" manifests/aws-logging-cloudwatch-configmap.yaml
sed -i.bk "s/PLACEHOLDER_REGION/${AWS_REGION}/g" manifests/aws-logging-cloudwatch-configmap.yaml

NamespaceAwsObservability=$(kubectl get namespace aws-observability 2> /dev/null | grep -v "^NAME" | awk '{print $1}')
if [ "${NamespaceAwsObservability}" == "" ]
then
  kubectl apply -f manifests/aws-observability-namespace.yaml
fi

ConfigMapAwsObservability==$(kubectl get configmap aws-logging 2> /dev/null | grep -v "^NAME" | awk '{print $1}')
if [ "${ConfigMapAwsObservability}" == "" ]
then
  kubectl apply -f manifests/aws-logging-cloudwatch-configmap.yaml
 fi

EksFargateLoggingPolicy=$(aws iam get-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/eks-fargate-logging-policy --output text 2> /dev/null | grep POLICY | awk '{print $2}')
FargatePodExecutionRole=$(eksctl get fargateprofile --cluster ${AMX_PPL_CLUSTER_EKS} --region ${AWS_REGION} | tail -1 | awk '{print $4}' | awk -F'/' '{print $2}')
if [ "${FargatePodExecutionRole}" == "" ]
then
  echo "Missing FargatePodExecutionRole"
  exit 1;
fi

if [ "${EksFargateLoggingPolicy}" == "" ]
then
  aws iam create-policy \
    --policy-name eks-fargate-logging-policy \
    --policy-document file://permissions.json
fi

if [ "arn:aws:iam::${ACCOUNT_ID}:role/EKS-Fargate-ADOT-ServiceAccount-Role" ] 
then
  aws iam attach-role-policy \
    --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/eks-fargate-logging-policy \
    --role-name ${FargatePodExecutionRole}
fi
rm -vf permissions.json

####################
### Installation HPA
####################
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
sed -i.bk "s/PLACEHOLDER_APP/${AMX_PPL_CLUSTER_EKS}/g" manifests/hpa-cpu.yaml
sed -i.bk "s/PLACEHOLDER_NAMESPACE_APP/${AMX_PPL_NAMESPACE}/g" manifests/hpa-cpu.yaml
rm -vf manifests/hpa-cpu.yaml.bkp

NamespacePplApp=$(kubectl get namespace ${AMX_PPL_NAMESPACE} 2> /dev/null | grep -v "^NAME" | awk '{print $1}')
if [ "${NamespacePplApp}" == "" ]
then
  eksctl create namespace ${AMX_PPL_NAMESPACE}
fi
kubectl apply -f manifests/hpa-cpu.yaml

kubectl get pods -A -o wide
kubectl get deployment -A -o wide
kubectl top pods -A