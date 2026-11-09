# Crossplane lab

A small, hands-on way to learn Crossplane on the talos cluster. You make your own Kubernetes API, `WebApp`,
and Crossplane turns every `WebApp` into a ConfigMap, a Deployment and a Service. No cloud account needed.

Crossplane itself is already installed by Argo CD ([apps/crossplane.yaml](../apps/crossplane.yaml)).
The files in this folder are **not** watched by Argo CD. You apply them by hand, so you can break things.

## Crossplane in 5 ideas

1. **Crossplane adds your own APIs to Kubernetes.** You decide that `kind: WebApp` exists, and what fields it has.
2. **XRD = the shape of the API.** The CompositeResourceDefinition says which fields a `WebApp` has
   (`message`, `replicas`). It says nothing about how to build it.
3. **Composition = the recipe.** "For every WebApp, create a ConfigMap, a Deployment and a Service, and copy
   these fields into them."
4. **Function = the program that runs the recipe.** Here `function-patch-and-transform`: it copies fields
   ("patches") and can change them on the way ("transforms").
5. **XR = a request.** A `WebApp` object you create is a *composite resource* (XR). Crossplane keeps the
   resources it created in line with it. Delete one, and Crossplane creates it again.

```
 you write              Crossplane reads           Crossplane creates
 ─────────              ────────────────           ──────────────────
 WebApp "hello"   ──▶   XRD (is it valid?)    ──▶  ConfigMap  hello-page
 (the XR)               Composition (recipe)       Deployment hello-xxxxx  (nginx)
                        Function (runs it)         Service    hello-xxxxx
```

**Providers** are the next step (not in this lab). A provider teaches Crossplane an outside API: AWS, Azure,
Proxmox, GitHub... Each thing it creates there (a VM, a bucket) is a **managed resource**. A Composition can
mix both: plain Kubernetes objects, like here, and managed resources from providers.

## The lab

Run from this folder. `kubectl` already points at talos.

**1. Install the function.** Crossplane downloads it and runs it as a pod.

```bash
kubectl apply -f 01-function.yaml
kubectl get functions                       # wait until HEALTHY is True
kubectl -n crossplane-system get pods       # see the function pod
```

**2. Give Crossplane permission** to create ConfigMaps, Deployments and Services.

```bash
kubectl apply -f 02-rbac.yaml
```

**3. Create the API.** After this, `WebApp` is a real Kubernetes kind.

```bash
kubectl apply -f 03-xrd.yaml
kubectl get xrd                             # ESTABLISHED should be True
kubectl explain webapp.spec                 # Kubernetes now knows your fields
```

**4. Add the recipe.**

```bash
kubectl apply -f 04-composition.yaml
```

**5. Ask for a web app.**

```bash
kubectl apply -f 05-webapp.yaml
kubectl get webapp                          # wait until READY is True (~30 s)
kubectl get cm,deploy,svc -l crossplane.io/composite=hello
```

**6. Look at it.**

```bash
kubectl port-forward svc/$(kubectl get svc -l crossplane.io/composite=hello -o name | cut -d/ -f2) 8080:80
```

Open http://localhost:8080. It shows "Hello from Crossplane!".

## Practice

Do them in order. Each one teaches one idea.

1. **Change the request.** `kubectl edit webapp hello` and set `replicas: 3`. Run
   `kubectl get deploy -l crossplane.io/composite=hello`: 3 pods. You changed one field and Crossplane updated
   the Deployment.
2. **Self-healing.** Delete the Deployment:
   `kubectl delete deploy -l crossplane.io/composite=hello`. Wait a minute and look again: it is back.
   Crossplane keeps checking that what exists matches the recipe.
3. **Follow the chain.** `kubectl describe webapp hello`. Look at `Resource Refs` (what it created) and the
   events at the bottom. Then `kubectl get deploy -l crossplane.io/composite=hello -o yaml` and find the
   `ownerReferences`: the Deployment belongs to the WebApp.
4. **The schema protects you.** Remove `message` from [05-webapp.yaml](05-webapp.yaml) and apply it again
   under another name. Kubernetes refuses it: `message` is required in the XRD.
5. **Add a field.** Let users choose the nginx image:
   - in [03-xrd.yaml](03-xrd.yaml), add `image: {type: string, default: "nginx:1.29-alpine"}` next to `replicas`
   - in [04-composition.yaml](04-composition.yaml), add a patch to the deployment:
     `fromFieldPath: spec.image`, `toFieldPath: spec.template.spec.containers[0].image`
   - apply both, then set `image: nginx:1.28-alpine` in your WebApp. Check with
     `kubectl get deploy -l crossplane.io/composite=hello -o jsonpath='{..image}'`.
6. **Break the recipe.** Make a typo in a `toFieldPath` in the Composition and apply it.
   `kubectl describe webapp hello` shows the error. Fix it again.
7. **Delete the request.** `kubectl delete webapp hello`. Everything it created is deleted too.

## Clean up

```bash
kubectl delete -f 05-webapp.yaml -f 04-composition.yaml -f 03-xrd.yaml -f 02-rbac.yaml -f 01-function.yaml
```

## Next steps

- **A provider.** Install `provider-kubernetes` or a Proxmox provider and create a managed resource. Providers
  need permissions (in the cluster, or an API token for the outside system). Start with the
  [Crossplane docs](https://docs.crossplane.io).
- **GitOps.** When an API works, move its files into an Argo CD app (a file in [apps/](../apps/)), like
  every other app here.
