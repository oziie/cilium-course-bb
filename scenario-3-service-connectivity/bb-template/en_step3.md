### Service Connectivity

#### Step 3 — Reach nginx Through the Service

Call nginx from the client pod using the **Service name**:

```bash
kubectl exec pod/netshoot-client -- curl -s http://nginx-service
```

You get the **Welcome to nginx!** page. The short name works because both pods are in
the same namespace (`default`). From another namespace you would use
`nginx-service.default`.

See how the name is resolved:

```bash
kubectl exec pod/netshoot-client -- nslookup nginx-service
```

The answer is the **ClusterIP** of the Service, not the pod IP. The cluster DNS (CoreDNS)
always returns this stable address.

Now call the ClusterIP directly and print only the HTTP status code:

```bash
CLUSTER_IP=$(kubectl get service nginx-service -o jsonpath='{.spec.clusterIP}')
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" http://$CLUSTER_IP
```

The answer is `200`. The client talks to the ClusterIP, and the request still reaches the
nginx pod on the other node.
