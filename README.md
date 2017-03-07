## Adding Additional Users and Configuring ABAC for Kubernetes

This is a quick tutorial on how to add additional users to your kubernetes cluster.  

**Note that are no actual users inside of kubernetes so this is really more about controlling access to the kubernetes API and namespaces.**

I assume you have built out a cluster -- I used KOPS in AWS as the basis for what's below.  

Here are the basic steps demonstrated:
  - create a new set of keys (authentication step - AuthN) using the certs existing on the masters
  - create the user or token (authorization step - AuthZ) and modify the local file 
  - set up ABAC AuthZ for more fine grained-ish resource/namespace control
  - restart kube-apiserver docker container on masters to pick the change up

Also see the following kubernetes ref docs:

[https://kubernetes.io/docs/admin/accessing-the-api/](https://kubernetes.io/docs/admin/accessing-the-api/)

particularly this overview doc:

[https://kubernetes.io/images/docs/admin/access-control-overview.svg](https://kubernetes.io/images/docs/admin/access-control-overview.svg)

[https://kubernetes.io/docs/admin/authentication/](https://kubernetes.io/docs/admin/authentication/)


## AuthN -- Gen Some Keys On Master

We want to create a separate cert for each user that we're going to support.  This is the authorization state -- basically the certs generated will tell the kube-api that we're ok to talk to it.

```
  openssl genrsa -out tcotav.pem 2048
  openssl req -new -key tcotav.pem -out tcotav.csr -subj "/CN=tcotav,O=admin"
  openssl x509 -req -in tcotav.csr -CA /srv/kubernetes/server.cert -CAkey /srv/kubernetes/server.key -CAcreateserial -out tcotav.crt -days 365
```


Or use the keygen script

  - scp `keygen.sh` to master
  - change the NEWNAME variable to whatever you want
  - run it for each user that you need to create

this will generate the following files:

  - \<NEWNAME\>.crt
  - \<NEWNAME\>.csr
  - \<NEWNAME\>.pem

Also copy the `ca.crt` to your HOME dir as well as this is required in your kubeconfig later.

```
cp /srv/kubernetes/ca.crt ~/
```

We do this for each user we want to add.  When you're done, retrieve the keys from the master and distribute as appropriate.


## AuthZ -- Next step, modify known_tokens.csv

We'll be adding our user, NEWNAME, into the known_tokens.csv file.  This is the other part of communicating with the k8s API -- authN says its ok to talk to us at all, authZ says what requests we're allowed to make. 

You can create some random noise to be your token by running this on the unix master host (stolen from the internet):

```
dd if=/dev/urandom bs=128 count=1 2>/dev/null | base64 | tr -d "=+/" | dd bs=32 count=1 2>/dev/null
```

take whatever is gen'd there and add a line to the file in format like the following:

```
1R2l9tgQ1i42H0Im9ueBTYxKK0Qkk8Y7,tcotav,kube
```

To pick this change up, we'll have to restart kube-apiserver, but lets wait on that.

Don't lose track of that token though, we'll need it to assemble our complete kubeconfig file to talk to this cluster.

Alternately, you can use `htpasswd` to generate a `basic_auth` password if you'd prefer that for your authN as seen above.  The username and password goes on the master in `/srv/kubernetes/basic_auth.csv` and goes into the kubeconfig as is shown above.


### Sample kubeconfig

Here's a sample snippet of what the user section of a kubeconfig would look like using the values we generated for user "tcotav" -- keys, ca.cert, and the token, after copying all the certs and pem to my local laptop:

```
apiVersion: v1
clusters:
- cluster:
    certificate-authority: /Users/tcotav/k8s-demo/ca.crt
    server: https://api.demo001.k8s.gnslngr.us
  name: demo001.k8s.gnslngr.us
contexts:
- context:
    cluster: demo001.k8s.gnslngr.us
    user: demo001.k8s.gnslngr.us
  name: demo001.k8s.gnslngr.us
current-context: demo001.k8s.gnslngr.us
kind: Config
preferences: {}
users:
- name: demo001.k8s.gnslngr.us
  user:
    client-certificate: /Users/tcotav/k8s-demo/tcotav-demo001.crt
    client-key: /Users/tcotav/k8s-demo/tcotav-demo001.pem
    #
    ### can use EITHER token or u/p
    ### maps to basic_auth.csv OR known_tokens.csv on master
    #
    token: 1R2l9tgQ1i42H0Im9ueBTYxKK0Qkk8Y7
#    password: 1R2l9tgQ1i42H0Im9ueBTYxKK0Qkk8Y7
#    username: tcotav
```

I assembled this manually, but you should [do it the right way and use kubectl](https://kubernetes.io/docs/user-guide/kubectl/kubectl_config_set-credentials/)



### Manual "restart" of kube-apiserver container 

Don't do this right now but its handy to have if you need to. To restart the kube-apiserver docker container, we first have to find it:

```
docker ps | grep kube-api
```

Here's a magical incantation that'll grab the first one (which should be the running one), grabs the container id, and then does the kill on it:

```
docker ps | grep kube-api | head -n1 | cut -c1-12 | xargs docker kill
```

This will kill the former container and start a new one (picking up the new configs along the way).

If you run the following again:

```
docker ps | grep kube-api
```

you'll see the uptime on the apiserver shows the restart.


## ABAC -- more granular authN

We're going to use this to lock down specific users to specific namespaces.  This is how we're going to be able to achieve SOX/PCI compliance inside a single cluster (versus having to break out a separate cluster to isolate apps that have compliance requirements).  Soon, I'll add on RBAC to this, but its not fully (well?) supported yet.


### Create the abac authn json file

Edit the file "abac-authn.json" included in this repo to add the users you've added to your overall cluster -- adding one line per user

```
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user":"tcotav", "namespace":"\*", "resource": "\*", "apiGroup": "\*", "nonResourcePath": "\*"}}
```

Lock down what you need to lock down for that user.  For example, we create a namespace "sox" and want to lock down user tcotav-sox to that namespace, then we'd create a line like this:

```
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user":"tcotav-sox", "namespace":"sox", "resource": "\*", "apiGroup": "\*", "nonResourcePath": "\*"}}
```

### What's an ABAC file?

As you can see from the above, it allows us to restrict a user to specific namespaces, resources, apiGroups, or nonResourcePath.  I don't know what some of those are, but the docs will probably tell you.  I mostly use the namespace part.

### Get the JSON file up on the master

Copy both `abac-authn.json` up to the master.

On the master,

```
sudo cp abac-authn.json /srv/kubernetes
```

Now the potentially tricky part -- we're going to modify the `kube-apiserver.manifest` file.  If you're worried that you'll mess up, make a copy of the original.  We'll also be copying over one for us to modify.

```
cp /etc/kubernetes/manifests/kube-apiserver.manifest ./kube-apiserver.manifest.original
cp /etc/kubernetes/manifests/kube-apiserver.manifest ./kube-apiserver.manifest
```

Open kube-apiserver.manifest and change the following line:

```
    - "/usr/local/bin/kube-apiserver --address=127.0.0.1 --admission-control=NamespaceLifecycle,LimitRanger,ServiceAccount,PersistentVolumeLabel,DefaultStorageClass,ResourceQuota --allow-privileged=true --anonymous-auth=false --apiserver-count=1 --basic-auth-file=/srv/kubernetes/basic_auth.csv --client-ca-file=/srv/kubernetes/ca.crt --cloud-provider=aws --etcd-servers-overrides=/events#http://127.0.0.1:4002 --etcd-servers=http://127.0.0.1:4001 --kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP,LegacyHostIP --secure-port=443 --service-cluster-ip-range=100.64.0.0/13 --storage-backend=etcd2 --tls-cert-file=/srv/kubernetes/server.cert --tls-private-key-file=/srv/kubernetes/server.key --token-auth-file=/srv/kubernetes/known_tokens.csv --v=2 1>>/var/log/kube-apiserver.log 2>&1"
```

to look like this:

```
    - "/usr/local/bin/kube-apiserver --authorization-mode=ABAC --authorization-policy-file=/srv/kubernetes/abac-authn.json --address=127.0.0.1 --admission-control=NamespaceLifecycle,LimitRanger,ServiceAccount,PersistentVolumeLabel,DefaultStorageClass,ResourceQuota --allow-privileged=true --anonymous-auth=false --apiserver-count=1 --basic-auth-file=/srv/kubernetes/basic_auth.csv --client-ca-file=/srv/kubernetes/ca.crt --cloud-provider=aws --etcd-servers-overrides=/events#http://127.0.0.1:4002 --etcd-servers=http://127.0.0.1:4001 --kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP,LegacyHostIP --secure-port=443 --service-cluster-ip-range=100.64.0.0/13 --storage-backend=etcd2 --tls-cert-file=/srv/kubernetes/server.cert --tls-private-key-file=/srv/kubernetes/server.key --token-auth-file=/srv/kubernetes/known_tokens.csv --v=2 1>>/var/log/kube-apiserver.log 2>&1"
```

or basically adding this after the binary:

```
--authorization-mode=ABAC --authorization-policy-file=/srv/kubernetes/abac-authn.json 
```

to get it picked up you can run this:

```
sudo cp kube-apiserver.manifest /etc/kubernetes/manifest/
```

`kubelet` will note the change and reload the container with the new config.  You shoudn't have to do anything else at this point other than prepare to test.

and then test.

