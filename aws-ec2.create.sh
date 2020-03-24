#!/bin/bash
# Autor: Dumka
# 28/02/2019
#=== Constants
OK=1
ERROR=2
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
ME=$(whoami)
#=== Global Declarations
vol_file=''
user_data_file=''
vpc=''
subnet=''
ami_id=''


#=== Functions
usage() {
  echo "Usage:"
  echo -e "$0"
  echo -e "    ${GREEN} -n [name]${NC}            -- Short name of your instance"
  echo -e "    ${GREEN} -i [instance type]${NC}   -- Type of ec2 instance"
  echo -e "    ${GREEN} -t [network type]${NC}    -- External IP address: public/private"
  echo -e "    ${GREEN} -c [role]${NC}            -- Tag of the server role, short instance description"
  echo -e "    ${GREEN} -e [env]${NC}             -- Environemnt: prod/stage"
  echo -e "    ${GREEN} -r [region]${NC}          -- AWS region name"
  echo -e "    ${GREEN} -a [option]${NC}          -- Elastic IP association policy: yes/no"
  echo -e "    ${GREEN} -k [key]${NC}             -- The name of the key pair to access the machine"
  echo -e "    ${GREEN} -p [key]${NC}             -- The name of the project EC2 belongs to"
}

allocate_eip() {
# Allocate Elastic IP in region
  local aws_region="$1"
  local eip=$(aws ec2 allocate-address --domain vpc --region ${aws_region} 2>&1)
  echo ${eip}
}

create_user_data() {
# Creates local file with 'User Data' to provision ec2 instance
# with specific settings and data
  local aws_name="$1"
  local aws_region="$2"
  local aws_env="$3"
  local new_hostname=''
  local hostname_suffix=''
  local s3_suffix=''
  # Remove all dots in case FQDN provided as a host name in time of instance creation
  local ec2_name=$(echo "${aws_name}" | sed 's/\..*$//g')

  hostname_suffix=${aws_env}
  new_hostname="${ec2_name}.aws-${aws_region}.${hostname_suffix}"
cat > /tmp/int.txt  << EOF2
#!/usr/bin/env bash
## Installing needed soft
apt-get -y -o Acquire::ForceIPv4=true update
#apt-get -y upgrade  -q -y --force-yes
apt-get remove -y --purge irqbalance
apt-get install -y whois
apt-get install -y python2.7
apt install -y  python-pip
apt install -y  python-apt
pip install awscli
pip install docker
# Using service command for compatibility reasons
service ssh restart
sed -i "s/^127\..*$/127.0.0.1 ${new_hostname} ${ec2_name} localhost/" /etc/hosts
echo '169.254.169.254 aws.info' >> /etc/hosts
hostnamectl set-hostname ${new_hostname}
curl -o /root/bootstrap-salt.sh -L https://bootstrap.saltstack.com
sleep 2
shutdown -r now
EOF2

  user_data_file='file:///tmp/int.txt'
}

set_aws_keypair() {
# Choose which keypair the ec2 machine will be installed with
# This keypair should be created before using aws web interface or CLI
  local aws_region="$1"
  local key_name="$2"
  local tmp_name=''

  tmp_name=$(aws ec2 describe-key-pairs --region ${aws_region} \
  --query 'KeyPairs[*].KeyName' | grep "${key_name}" | sed 's/[ ",]//g')

  if [[ ! -z ${tmp_name} && ${tmp_name} == "${key_name}" ]]; then
    keypair="--key-name ${key_name}"
  else
    keypair=''
  fi
  echo "${keypair}"
}

check_aws_region() {
  local aws_region="$1"
  local all_regions=$(aws ec2 describe-regions --query "Regions[].{Name: RegionName}" --output text)

  echo $all_regions | grep -q $aws_region

  if [[ $? -ne 0 ]]; then
    echo "No such region available: $aws_region"
    exit $ERROR

  fi
}

check_ec2_exists() {
  local ec2_name="$1"
  local aws_region="$2"
  aws ec2 describe-instances --filters "Name=tag:Name,Values=${ec2_name}" \
  --region ${aws_region} | grep -iq instanceid

  if [[ $? -eq 0 ]]; then
    echo -e "${RED}Instance with name ${ec2_name} already exists${NC}"
    exit $ERROR
  fi
}

set_image_ami() {
  local aws_region="$1"
  local image_number=''
  local lsb=''
  local tmp='/tmp/aws'

  while true; do
    echo -e "Type major version number of the Ubuntu to be installed "
    echo -en ">> "
    read lsb
    if [[ ${lsb} =~ ^[0-9]+$ && ${lsb} -gt 0 ]]; then
      aws ec2 describe-images  --filters "Name=image-type,Values=machine" "Name=virtualization-type,Values=hvm" \
      "Name=state,Values=available" "Name=architecture,Values=x86_64" "Name=name,Values=*ubuntu*" "Name=description,Values=*${lsb}.*"\
      "Name=manifest-location,Values=*ubuntu/images/hvm-ssd/*" \
      "Name=description,Values=*LTS*" \
      --region ${aws_region}  \
      --query 'Images[*].[ImageId,ImageOwnerAlias,Architecture,VirtualizationType,Name]' \
      --output text > ${tmp}
       if [[ $(wc -l ${tmp} | awk '{print $1}') -gt 0 ]]; then
         break
       else
         echo -e "No images match provided ${RED}Major release ${NC}number were found. Try another one"
         sleep 2
         clear
       fi
    else
      echo -e "${RED}Type valid non-zero integer${NC}"
      sleep 1
      clear
    fi
  done

  local max_lines=$(wc -l ${tmp} | awk '{print $1}')

  clear
  while true; do
    echo -e  "Choose Ubuntu AMI image by line number and Image description:\n"
    echo -e "${RED}Number\tAMI-ID\t\t   Owner\t   Arch\t  Virt\tImage Name${NC}"
    nl -p ${tmp} | sed 's/^ *//' | column -t
    echo -en ">> "
    read  image_number
    if [[ $image_number =~ ^[0-9]+$ && $image_number -le $max_lines && $image_number -gt 0 ]]; then
      ami_id=$(cat ${tmp} | sed -n "${image_number}p" | awk  '{print $1}')  &&  break
    else
      echo -e "\n\n"
      echo -e "${RED}choosen line number does not exist${NC}"
      sleep 1
      clear
    fi
  done
}

set_vpc() {
  local aws_region="$1"
  local tmp='/tmp/aws'
  local vpc_number=''
  aws ec2 describe-vpcs --filters Name=state,Values=available \
  --query 'Vpcs[*].[VpcId,CidrBlock,IsDefault,Tags[?Key==`Name`].Value | [0]]' \
  --region ${aws_region} --output text > ${tmp}

  local max_lines=$(wc -l ${tmp} | awk '{print $1}')

  clear
  while true; do
    echo -e  "Choose VPC for the instance  by line number and description:\n"
    echo -e "${RED}Number\tVpc ID\t\tCidr\t\tDefault\tTags${NC}"
    nl -p ${tmp} | sed 's/^ *//'
    echo -en ">> "
    read  vpc_number

    if [[ $vpc_number =~ ^[0-9]+$ && $vpc_number -le $max_lines && $vpc_number -gt 0 ]]; then
      vpc=$(cat ${tmp} | sed -n "${vpc_number}p" | awk  '{print $1}')  &&  break
    else
      echo -e "\n\n"
      echo -e "${RED}choosen line number does not exist${NC}"
      sleep 1
      clear
    fi
  done
}

set_subnet() {
  local aws_region="$1"
  local tmp='/tmp/aws'
  local subnet_number=''
  aws ec2 describe-subnets --filters "Name=vpc-id,Values=${vpc}" \
	--query 'Subnets[*].[AvailabilityZone,AvailableIpAddressCount,SubnetId,Tags[?Key==`Name`].Value | [0]]' \
  --region ${aws_region} --output text  > ${tmp}

  local max_lines=$(wc -l ${tmp} | awk '{print $1}')

  clear
  while true; do
    echo -e  "Choose  availability zone by line number and subnet description:\n"
    echo -e "${RED}Number\tAV Zone\t\tIPs\tSubnet ID\tTags${NC}"
    nl -p ${tmp} | sed 's/^ *//'
    echo -en ">> "
    read  subnet_number

    if [[ $subnet_number =~ ^[0-9]+$ && $subnet_number -le $max_lines && $subnet_number -gt 0 ]]; then
      subnet=$(cat ${tmp} | sed -n "${subnet_number}p" | awk  '{print $3}')  &&  break
    else
      echo -e "\n\n"
      echo -e "${RED}choosen line number does not exist${NC}"
      sleep 1
      clear
    fi
  done
}

set_volume() {
  clear
  local vol_template=''
  local tmp='/tmp/aws'
  local template_number=''
  local yesno=''
  local vol_size=''
  local vol_type=''
  local templates=$(find . -depth 1 -type f -regex '^.*\.json' | sed -e 's|^.*/||; s|\.json$||')

  if [[ ! -z ${templates} ]]; then
    echo -e "Local templates found"
    for file in $(find . -depth 1 -type f -regex '^.*\.json' | sed -e 's|^.*/||; s|\.json$||'); do
      echo ${file}
    done

    echo -e "Do you want to use them as a ec2 volume template [Yy|Nn]"
    while true; do
      echo -en ">> "
      read yesno
      if [[ ${yesno} == 'N' || ${yesno} == 'n' ]]; then
        templates=''
        break
      elif [[ ${yesno} == 'Y' || ${yesno} == 'y' ]]; then
        break
      else
        echo "Please use 'Yy' or 'Nn' answer only"
        sleep 1
      fi
    done
  fi

	if [[ ! -z ${templates} ]]; then
    rm -f ${tmp}
    for file in $(find . -depth 1 -type f -regex '^.*\.json' | sed -e 's|^.*/||; s|\.json$||'); do
      echo ${file} >> ${tmp}
    done
    local max_lines=$(wc -l ${tmp} | awk '{print $1}')

    while true; do
      echo -e "Found foollowing JSON templates, choose the one to use:"
      nl -p ${tmp} | sed 's/^ *//'
      echo -en ">> "
      read template_number

      if [[ $template_number =~ ^[0-9]+$ && $template_number -le $max_lines && $template_number -gt 0 ]]; then
        vol_template=$(cat ${tmp} | sed -n "${template_number}p" | awk  '{print $1}')  &&  break
      else
        echo -e "\n\n"
        echo -e "${RED}choosen line number does not exist${NC}"
        sleep 1
        clear
      fi
    done
    vol_file="file://${vol_template}.json"
  else
    echo -e "No local JSON templates found"
    echo -e "Configuring disk manually"
    while true; do
	    echo -e "Enter volume size in GB "
		  echo -en ">> "
		  read vol_size

      if [[ ! -z ${vol_size} && ${vol_size} =~ ^[0-9]+$ && ${vol_size} -gt 8 ]]; then
		    break
      else
		    echo "Volume size cant be empty,  non-numberic or less then 8 Gb"
			sleep 1
			clear
      fi
    done

	  while true; do
        echo -e "Enter volume type as 'gp2' or 'io1' "
        echo -en ">> "
        read vol_type

        if [[ ${vol_type} == 'gp2'  ||  ${vol_type} == 'io1' ]]; then
          break
        else
          echo "Unsupported/Wrong volume type received"
          sleep 1
          clear
        fi
    done

cat > /tmp/config.json << EOF
[
  {
    "DeviceName": "/dev/sda1",
    "Ebs": {
      "DeleteOnTermination": true,
      "VolumeSize": ${vol_size},
      "VolumeType": "${vol_type}"
    }
  }
]
EOF
  vol_file="file:///tmp/config.json"
  fi
}

set_public_ip_status() {
  local ip_type="$1"
  local public_ip_status=''
  case ${ip_type} in
    public)
      public_ip_status='--associate-public-ip-address'
    ;;
    private)
      public_ip_status='--no-associate-public-ip-address'
    ;;
    esac
    echo "${public_ip_status}"
}

aws_ec2_create() {
  local aws_instance=''
  local ec2_name="$1"
  local ec2_type="$2"
  local public_ip_status="$3"
  local aws_env="$4"
  local role="$5"
  local aws_region="$6"
  local keypair="$7"
  local project="$8"

  aws_instance=$(aws ec2 run-instances \
  --image-id ${ami_id} --count 1 --instance-type ${ec2_type} ${keypair} ${public_ip_status} \
	--tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${ec2_name}}, \
    {Key=Department,Value='Engineering Services'}, \
    {Key=Expiration,Value=''}, \
    {Key=TeamOwner,Value=${ME}}, \
    {Key=Finance,Value='RnD'}, \
    {Key=Environemnt,Value=${aws_env}}, \
    {Key=Project,Value=${project}}, \
    {Key=Role,Value=${role}}]" \
	--subnet-id ${subnet} \
	--block-device-mappings ${vol_file} \
  --user-data ${user_data_file} \
	--region ${aws_region} 2>&1)

  echo "aws ec2 run-instances --image-id ${ami_id} --count 1 --instance-type ${ec2_type} ${public_ip_status} --subnet-id ${subnet}\ 
        --block-device-mappings ${vol} --user-data ${user_data_file} --region ${aws_region}"
	echo ${aws_instance}
}

cleanup() {
  rm -f /tmp/config.json
  rm -f /tmp/int.txt
}

main() {
  ### Main
  local public_ip_status=''
  local user_data_file=''
  local key_name=''
  local keypair
  local instance=''
  local aws_region=''
  local eip_association='no'
  local project=''

  if [[ -z $@ ]]; then
    usage
    exit $ERROR
  fi
  while getopts "n:i:t:c:e:r:a:k:p:h" opt; do
    case ${opt} in
      n)
        ec2_name=$OPTARG
        ;;
      i)
        ec2_type=$OPTARG
        ;;
      t)
        ip_type=$OPTARG
        ;;
      c)
        role=$OPTARG
        ;;
      e)
        aws_env=$OPTARG
        ;;
      r)
        aws_region=$OPTARG
        ;;
      k)
        key_name=$OPTARG
        ;;
      a)
        eip_association=$OPTARG
        ;;
      p)
        project=$OPTARG
        ;;
      h|*)
        usage
        exit $OK
      ;;
    esac
  done

  echo "Parsing arguments and  checking their validity"
  echo "Please wait"

  if [[ -z ${project} ]]; then
    echo "Project can not be empty"
    exit ${ERROR}
  fi

  if [[ ! -z ${key_name} ]]; then
    keypair=$(set_aws_keypair ${aws_region} ${key_name})
    if [[ ! -z "${keypair}" ]]; then
      echo -e "\n${GREEN}Key pair found in region where machine is created."
      echo -e "make sure you have private key of key pair accesible${NC}\n"
    else
      echo -e "${RED}Key pair name does not exist in region where machine is going to be created${NC}"
    fi
  else
    echo -e "${RED}Key pair name can not be empty${NC}"
  fi

  if [[ -z ${ec2_name} ]]; then
    echo "Instance name can not be empty"
    exit $ERROR
  fi

  if [[ -z ${ec2_type} ]]; then
    echo "Instance type can not be empty"
    exit $ERROR
  fi

  if [[ ${ip_type} != 'public' &&  ${ip_type} != 'private' ]]; then
    echo -e "${RED}Network type be only 'public' or 'private'${NC}"
    echo -e "${RED}You used: ${ip_type} ${NC}"
    exit $ERROR
  fi

  if [[ ${ip_type} != 'public' && ${eip_association} == 'yes' ]]; then
    echo -e "${RED}You should not assign Elastic IP address to the instance without external network address${NC}"
    exit ${ERROR}
  fi

  if [[ -z ${eip_association} && ${ip_type} == 'public' ]]; then
    echo "Elastic IP allocation policy could not be empty"
    exit $ERROR
  else
    if [[ ${ip_type} == 'public' && ${eip_association} != 'yes' && ${eip_association} != 'no' ]]; then
      echo -e "${RED}Elastic IP association policy can be 'yes' or 'no'${NC}"
      exit $ERROR
    else
      echo ""
    fi
  fi

  if [[ -z ${role} ]]; then
    echo "Instance role can not be empty"
    exit $ERROR
  fi

  if [[ -z ${aws_env} ]]; then
    echo -e "${RED}aws profile should not be empty"
    exit $ERROR
  fi

  if [[ -z ${aws_region} ]]; then
    echo "Instance region can not be empty"
    exit $ERROR
  fi

  check_aws_region ${aws_region}
  check_ec2_exists ${ec2_name} ${aws_region}
  set_vpc ${aws_region}
  set_subnet ${aws_region}
  set_image_ami ${aws_region}
  public_ip_status=$(set_public_ip_status ${ip_type})

  trap cleanup INT TERM EXIT
  set_volume
  create_user_data ${ec2_name} ${aws_region} ${aws_env}

  yesno=''
  clear
  echo -e "The following machine will be created:                  \n"
  echo -e "Machine region:         ${GREEN}${aws_region}${NC}      \n"
  echo -e "Machine environment:    ${GREEN}${aws_env}${NC}         \n"
  echo -e "Machine name:           ${GREEN}${ec2_name}${NC}        \n"
  echo -e "Machine type:           ${GREEN}${ec2_type}${NC}        \n"
  echo -e "In VPC:                 ${GREEN}${vpc}${NC}             \n"
  echo -e "In Subnet:              ${GREEN}${subnet}${NC}          \n"

  if [[ ! -z ${keypair} ]]; then
    echo -e "With acess keyname:     ${GREEN}${key_name}${NC}        \n"
  fi
  if [[ ${ip_type} == 'public' ]]; then
    echo -e "With ${RED}Public${NC} IP address                     \n"
  else
    echo -e "With ${RED}Private${NC} IP address                    \n"
  fi
  echo -e "Using image:           ${GREEN}${ami_id}${NC}           \n"
  echo -e "With the following volumes:                             \n"
  cat $(echo $vol_file | sed 's/^file:..//')
  echo -e "\n\n"

  while true; do
    echo -e "Is it OK? [y|n] "
    echo -en ">> "
    read yesno
    if [[ ${yesno} == 'N' || ${yesno} == 'n' ]]; then
      echo "AWS instance creation has been cancelled"
      exit $OK
    elif [[ ${yesno} == 'Y' || ${yesno} = 'y' ]]; then
    echo "OK, starting AWS creation process"
      sleep 1
      break
    else
      echo "You shoud press [Yy] or [Nn]"
      sleep 1
    fi
  done

  echo -e "Creating ec2 instance, please wait"
  instance=$(aws_ec2_create ${ec2_name} ${ec2_type} "${public_ip_status}" ${aws_env} "${role}" ${aws_region} "${keypair}" "${project}")
  sleep 10

  if [[ $? -eq 0 ]]; then
    echo "Instance ${ec2_name} created. Adding it to the relevant security groups for ${ip_type} instance"
    if [[ ${ip_type} == 'public' && ${eip_association} == 'yes' ]]; then
      echo -e "Allocating and associating Elastic IP address for the instance. Please wait"
      elasitc_ip=$(allocate_eip ${aws_region})
      sleep 15
      instance_id=$(echo ${instance} | sed 's/[" ]//g' | awk -F, '{print $4}' | awk -F: '{print $2}')
      allocation_id=$(echo ${elasitc_ip} | sed 's/[" ]//g' | grep eipalloc | awk -F, '{print $2}' | awk -F: '{print $2}')
      if [[ ! -z ${allocation_id} ]]; then
        aws ec2 associate-address --instance-id ${instance_id} --allocation-id ${allocation_id} --region ${aws_region} > /dev/null 2>&1
        ext_ip=$(echo ${elasitc_ip} | sed 's/[" ]//g' | grep eipalloc | awk -F, '{print $1}' | awk -F: '{print $2}')
        sleep 5
      else
        echo -e "No elastic ips available: increase limit"
        echo -e "Creating machine with regular external IP address"
        echo -e "If this is a production machine do not forget to open its external ip on the publisher server"
      fi
    fi
    sleep 3
    echo "Done. Machine creation has finished with the following parameters:"
    echo -e "\n\n"
    echo -e "${instance}\n"
  else
    echo "Error occured while creating ${ec2_name}. Check with bash -x or manually in AWS console"
    #cleanup
    exit $ERROR
  fi
}

main "$@"
