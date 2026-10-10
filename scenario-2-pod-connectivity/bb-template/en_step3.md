### Pod Connectivity

#### Step 3 — Test Pod-to-Pod Connectivity

Save the IP of the nginx pod in a variable:

```bash
NGINX_IP=$(kubectl get pod -l app.kubernetes.io/name=nginx -o jsonpath='{.items[0].status.podIP}')
echo $NGINX_IP
```

From the client pod on `kind-worker`, request the nginx page on `kind-worker2`:

```bash
kubectl exec pod/netshoot-client -- curl -s http://$NGINX_IP
```

You get the HTML of the **Welcome to nginx!** page.

Now print only the HTTP status code:

```bash
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" http://$NGINX_IP
```

The answer is `200`: the request succeeded.

The two pods run on different nodes, so the request left `kind-worker`, travelled inside
the **VXLAN tunnel** that Cilium set up between the nodes, and was delivered to the nginx
pod on `kind-worker2`. You did not configure any route: Cilium handles pod-to-pod
connectivity across nodes on its own.
