#!/bin/bash -xv

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output=text)
AMX_PPL_ENV=$1
AMX_PPL_CLUSTER_EKS=$2
AMX_APP_PREFIX=$3
AMX_PPL_NAMESPACE=$4
AMX_PPL_VPC_ID=$5
AMX_PPL_ECR_REPO=$6
AWS_REGION="us-east-1"
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
kubectl get cm aws-auth -n kube-system -o yaml | grep rolearn | grep amx-ppl-cc-des-iam-rol-eks-deployer
kubectl get cm aws-auth -n kube-system -o yaml | grep rolearn | grep ${AMX_PPL_CLUSTER_EKS}-iam-rol-eks-deployer
kubectl get cm aws-auth -n kube-system -o yaml | grep rolearn | grep ${AMX_PPL_CLUSTER_EKS}-${ACCOUNT_ID}-${AWS_REGION}

EksCheckRoleBackend=$(kubectl get cm aws-auth -n kube-system -o yaml | grep rolearn | grep ${AMX_PPL_CLUSTER_EKS}-${ACCOUNT_ID}-${AWS_REGION})
if [ ! "${EksCheckRoleBackend}" ]
then
  ROLE="      groups:\n       - system:masters\n      rolearn: ${EKS_ROLE_BACKEND_ARN}\n      username: codebuild-eks"
  kubectl get -n kube-system configmap/aws-auth -o yaml | awk "/mapRoles: \|/{print;print \"${ROLE}\";next}1" > /tmp/aws-auth-patch-backend.yml
  kubectl patch configmap/aws-auth -n kube-system --patch "$(cat /tmp/aws-auth-patch-backend.yml)"
fi

oidc_provider=$(aws eks describe-cluster --name ${AMX_PPL_CLUSTER_EKS} --region ${AWS_REGION} --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
if [ ! ${oidc_provider} ]
then
  eksctl utils associate-iam-oidc-provider \
  --region ${AWS_REGION}                   \
  --cluster ${AMX_PPL_CLUSTER_EKS}         \
  --approve
fi