#creates infrastructure for a self managed kubernetes cluster in aws
#provisions a vpc with a public and private subnet
#public subnet contains the application load balancer, bastion host and internet and NAT gateways
#private subnet contains 3 master nodes and 3 worker nodes as well as an NLB

#declare terraform provider
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.27"
    }
  }

  required_version = ">= 0.14.9"
}

#set the region
provider "aws" {
  profile = "default"
  region  = "us-east-2"
}

#TODO: load ssh key from path 
#create aws key pair that will be added to the instances
resource "aws_key_pair" "ssh-key" {
  key_name   = ""
  public_key = ""
}

#create vpc
resource "aws_vpc" "main-vpc" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "main"
  }
}

#create private subnet
resource "aws_subnet" "private-subnet"{
  vpc_id            = aws_vpc.main-vpc.id
  cidr_block        = "10.0.0.0/24"
  availability_zone = "us-east-2c"

  tags = {
    "Name" = "private"
  }
}

#craete public subnet in a different availability zone (for load balancing requirements)
resource "aws_subnet" "public-subnet"{
  vpc_id            = aws_vpc.main-vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-2b"

  tags = {
    "Name" = "public"
  }
}

#create security group for bastion host
resource "aws_security_group" "bastion-host-sg" {
  name    = "bastion-host-sg"
  vpc_id  = aws_vpc.main-vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#create  security group for public facing load balancer
resource "aws_security_group" "public-lb-sg" {
  name    = "public-lb-sg"
  vpc_id  = aws_vpc.main-vpc.id
  
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }  

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#create private subnet security group for cluster nodes allowing all traffic on all ports
resource "aws_security_group" "private-subnet-sg" {

  name    = "private-subnet-sg"
  vpc_id  = aws_vpc.main-vpc.id
  
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#TODO: create network ACLs

#provision public IP addresses

#create an elastic ip for the nat gateway
resource "aws_eip" "nat-gateway-eip" {
  vpc = true
}

#create an elastic IP for the bastion host
resource "aws_eip" "bastion-host-eip" {
  vpc = true
}

#create an elastic IP for the application load balancer
resource "aws_eip" "alb-eip" {
  vpc = true
}

#create an internet gateway
resource "aws_internet_gateway" "public-internet-gateway" {
  vpc_id = aws_vpc.main-vpc.id
  
  tags = {
    Name = "public-internet-gateway"
  }
}

#create nat gateway
resource "aws_nat_gateway" "public-nat-gateway" {
  allocation_id = aws_eip.nat-gateway-eip.id
  subnet_id     = aws_subnet.public-subnet.id
  depends_on    = [aws_internet_gateway.public-internet-gateway]
  
  tags = {
    Name = "public-nat-gateway"
  }
}

#add route to default route table to configure main route table to be private
resource "aws_route" "private-routing-scheme" {
  route_table_id            = aws_vpc.main-vpc.main_route_table_id
  destination_cidr_block    = "0.0.0.0/0"
  nat_gateway_id            = aws_nat_gateway.public-nat-gateway.id 
}

#create a new route table in the vpc for use by the public subnet
resource "aws_route_table" "public-route-table" {

  vpc_id = aws_vpc.main-vpc.id
  
  tags = {
    Name = "public-rt"
  }
}

#add a route to the newly created public route table that targets the internet gateway to be used by public subnet
resource "aws_route" "public-routing-scheme" {
  route_table_id          = aws_route_table.public-route-table.id
  destination_cidr_block  = "0.0.0.0/0"
  gateway_id              = aws_internet_gateway.public-internet-gateway.id
}

#associate the public subnet to the public route table
resource "aws_route_table_association" "public-subnet-route-association" {
  subnet_id      = aws_subnet.public-subnet.id
  route_table_id = aws_route_table.public-route-table.id
}

#create bastion host in public subnet
resource "aws_instance" "bastion" {
  ami                    = "ami-03b6c8bd55e00d5ed" #ubuntu
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.public-subnet.id  
  vpc_security_group_ids = [aws_security_group.bastion-host-sg.id]
  key_name               = aws_key_pair.ssh-key.key_name
  
  tags = {
    Name = "bastion"
  }
}

#associate elastic IP with bastion host
resource "aws_eip_association" "bastion-eip-assoc" {
  instance_id   = aws_instance.bastion.id
  allocation_id = aws_eip.bastion-host-eip.id
}

#create master nodes
resource "aws_instance" "master" {
  count                  = 3
  ami                    = "ami-03b6c8bd55e00d5ed" #ubuntu - "ami-00f8e2c955f7ffa9b" #centos7 
  instance_type          = "t2.medium"
  subnet_id              = aws_subnet.private-subnet.id  
  vpc_security_group_ids = [aws_security_group.private-subnet-sg.id]
  key_name               = aws_key_pair.ssh-key.key_name

  tags = {
    Name = "master${count.index + 1}"
  }
}

#create worker nodes
resource "aws_instance" "worker" {
  count                  = 3
  ami                    = "ami-03b6c8bd55e00d5ed" #00f8e2c955f7ffa9b"#  03b6c8bd55e00d5ed"
  instance_type          = "t2.medium"
  subnet_id              = aws_subnet.private-subnet.id
  vpc_security_group_ids = [aws_security_group.private-subnet-sg.id]
  key_name               = aws_key_pair.ssh-key.key_name
  
  tags = {
    Name = "worker${count.index + 1}"
  }
}

#create network load balancer (NLB) to split internal traffic from workers to master nodes
resource "aws_lb" "network-lb" {
  name                        = "network-lb"
  internal                    = true
  load_balancer_type          = "network"
  enable_deletion_protection  = false
  depends_on                  = [aws_subnet.private-subnet]
  
  subnet_mapping  {
    subnet_id = aws_subnet.private-subnet.id
  }

  tags = {
    Environment = "production"
  }
}

#create the NLB target group for worker to master communication
resource "aws_lb_target_group" "network-lb-tg" {
  name        = "network-lb-target-group"
  port        = 6443
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = aws_vpc.main-vpc.id
}

#create the NLB listener on port 6443 for kubernetes
resource "aws_lb_listener" "network-lb-listener" {
  load_balancer_arn = aws_lb.network-lb.arn
  port              = "6443"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.network-lb-tg.arn
  }
}

#add instances to the NLB target group
resource "aws_lb_target_group_attachment" "master-tg-attachment" {
  count            = 3
  target_group_arn = aws_lb_target_group.network-lb-tg.arn
  target_id        = aws_instance.master[count.index].private_ip
  port             = 6443
}

#create a classic load balancer to route traffic from the public subnet to worker instances in the private subnet
resource "aws_elb" "classic-lb" {
  name                  = "classic-lb"
  subnets               = [aws_subnet.public-subnet.id, aws_subnet.private-subnet.id]
  security_groups       = [aws_security_group.public-lb-sg.id]

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 8
    target              = "HTTP:80/healthz"
    interval            = 10
  }

  instances                   = [aws_instance.worker[0].id, aws_instance.worker[1].id, aws_instance.worker[2].id]
  idle_timeout                = 400
  connection_draining         = true
  connection_draining_timeout = 400
  cross_zone_load_balancing   = true

}
