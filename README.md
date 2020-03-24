<h3> This script will create aws ec2 instance in choosen region. </h3>
Script will create ec2 instance,

You will be asked about about vpc, subnet (availability zone), ubuntu version.
Publisher iptables will be modified to allow https access from the intance external IP. 
User `ubuntu` will be the default login user, as  you provide valid AWS access keypair (no password)

Instance disk size and type should be provided.
For more complex disk configurations, create json file with disks mappings,
and put it to the workind directory where script run

<b>Json file example:</b>
```
 [
  {
    "DeviceName": "/dev/sda1",
    "Ebs": {
      "DeleteOnTermination" : true,
      "VolumeSize": 50,
      "VolumeType": "gp2"
    }
  },
  {
    "DeviceName": "/dev/sdb",
    "Ebs": {
       "DeleteOnTermination": false,
       "VolumeSize": 1000,
       "VolumeType": "io1",
       "Iops" : 9000
    }
  }
 ]
```

<h3>Usage:</h3>

```
aws-ec2.create.sh -n [name] -t [instance type] -t [networking] -c [role] -e [environment] -r [aws region] -a [elastic ip association] -k [key]
```

```
[name]                - Name of your instance
[instance type]       - Type of ec2 instance: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-types.html
[network type]        - External IP address: public/private
[role]                - Tag of the server role, short instance description
[env]                 - Environemnt: prod/stage
[region]              - AWS region name
[option]              - Elastic IP association policy: yes/no
[key]                 - The name of the key pair to access the machine
[project]             - The name of the Project this machine belongs to (in Tags)
```
<h3>Example:</h3>

```
 aws-ec2.create.sh -n cassandra-1 -i c5.2xlarge -t private -c 'Cassandra main' -e prod -r eu-west-1 -k eu-west-1 -p Analytics
```
