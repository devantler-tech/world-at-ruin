package allocatordiscovery

import (
	"net/netip"

	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	"k8s.io/apimachinery/pkg/labels"
)

// join rejects ambiguous identity or socket ownership instead of choosing a page.
func (r *Reader) join(pods []corev1.Pod, slices []discoveryv1.EndpointSlice) ([]Member, error) {
	members := make([]Member, 0, len(pods))
	byUID := make(map[string]int, len(pods))
	names := make(map[string]bool, len(pods))
	addresses := make(map[string]map[netip.Addr]bool, len(pods))
	for _, pod := range pods {
		member, err := observe(pod)
		if err != nil || pod.Namespace != r.config.Namespace || !r.selector.Matches(labels.Set(pod.Labels)) || names[pod.Name] {
			return nil, ErrObservation
		}
		if _, duplicate := byUID[member.Identity.UID]; duplicate {
			return nil, ErrObservation
		}
		ips, err := podAddresses(pod)
		if err != nil {
			return nil, err
		}
		addresses[member.Identity.UID] = ips
		byUID[member.Identity.UID] = len(members)
		names[pod.Name] = true
		members = append(members, member)
	}
	seenSlices := make(map[string]bool, len(slices))
	seenNames := make(map[string]bool, len(slices))
	type owner struct {
		uid      string
		endpoint Endpoint
	}
	seenEndpoints := make(map[netip.AddrPort]owner)
	work := 0
	for _, slice := range slices {
		port, err := r.slicePort(slice)
		if err != nil || seenSlices[string(slice.UID)] || seenNames[slice.Name] {
			return nil, ErrObservation
		}
		seenSlices[string(slice.UID)] = true
		seenNames[slice.Name] = true
		for _, endpoint := range slice.Endpoints {
			ref := endpoint.TargetRef
			// ObjectReference's API version is optional. A supplied version must
			// still name core/v1; the exact Pod identity is required in both forms.
			if ref == nil || (ref.APIVersion != "" && ref.APIVersion != "v1") || ref.Kind != "Pod" || ref.Namespace != r.config.Namespace || len(endpoint.Addresses) == 0 || len(endpoint.Addresses) > 100 {
				return nil, ErrObservation
			}
			index, ok := byUID[string(ref.UID)]
			if !ok || members[index].Identity.Name != ref.Name {
				return nil, ErrObservation
			}
			for _, raw := range endpoint.Addresses {
				work++
				if work > 10000 {
					return nil, ErrObservation
				}
				ip, err := parseAddress(raw)
				if err != nil || (ip.Is4() && slice.AddressType != discoveryv1.AddressTypeIPv4) || (ip.Is6() && slice.AddressType != discoveryv1.AddressTypeIPv6) || !addresses[string(ref.UID)][ip] {
					return nil, ErrObservation
				}
				observed := Endpoint{Address: ip, Port: port, Ready: condition(endpoint.Conditions.Ready), Serving: condition(endpoint.Conditions.Serving), Terminating: condition(endpoint.Conditions.Terminating), Deleting: slice.DeletionTimestamp != nil}
				key := netip.AddrPortFrom(ip, port)
				if previous, ok := seenEndpoints[key]; ok {
					if previous.uid != string(ref.UID) || previous.endpoint != observed {
						return nil, ErrObservation
					}
					continue
				}
				seenEndpoints[key] = owner{uid: string(ref.UID), endpoint: observed}
				members[index].Endpoints = append(members[index].Endpoints, observed)
			}
		}
	}
	sortMembers(members)
	return members, nil
}

// slicePort binds the configured TCP port to the exact controlling Service UID.
func (r *Reader) slicePort(slice discoveryv1.EndpointSlice) (uint16, error) {
	if !validIdentity(Identity{slice.Namespace, slice.Name, string(slice.UID)}) || slice.Namespace != r.config.Namespace || !token(slice.ResourceVersion, 1024) ||
		slice.Labels[discoveryv1.LabelServiceName] != r.config.ServiceName || len(slice.Endpoints) > 1000 || len(slice.Ports) > 100 ||
		(slice.AddressType != discoveryv1.AddressTypeIPv4 && slice.AddressType != discoveryv1.AddressTypeIPv6) {
		return 0, ErrObservation
	}
	owners := 0
	for _, owner := range slice.OwnerReferences {
		if owner.Controller != nil && *owner.Controller {
			if owner.APIVersion != "v1" || owner.Kind != "Service" || owner.Name != r.config.ServiceName || string(owner.UID) != r.config.ServiceUID {
				return 0, ErrObservation
			}
			owners++
		}
	}
	if owners != 1 {
		return 0, ErrObservation
	}
	var port uint16
	for _, candidate := range slice.Ports {
		if candidate.Name == nil || *candidate.Name != r.config.PortName {
			continue
		}
		if port != 0 || candidate.Port == nil || *candidate.Port < 1 || *candidate.Port > 65535 || candidate.Protocol == nil || *candidate.Protocol != corev1.ProtocolTCP {
			return 0, ErrObservation
		}
		port = uint16(*candidate.Port)
	}
	if port == 0 {
		return 0, ErrObservation
	}
	return port, nil
}

// podAddresses reconciles the primary and dual-stack status fields without
// accepting contradictory or duplicate addresses.
func podAddresses(pod corev1.Pod) (map[netip.Addr]bool, error) {
	if len(pod.Status.PodIPs) > 2 {
		return nil, ErrObservation
	}
	ips := make(map[netip.Addr]bool, 2)
	for _, raw := range pod.Status.PodIPs {
		ip, err := parseAddress(raw.IP)
		if err != nil || ips[ip] {
			return nil, ErrObservation
		}
		ips[ip] = true
	}
	if pod.Status.PodIP != "" {
		ip, err := parseAddress(pod.Status.PodIP)
		if err != nil || (len(ips) > 0 && !ips[ip]) {
			return nil, ErrObservation
		}
		ips[ip] = true
	}
	return ips, nil
}

// parseAddress permits only canonical address families usable for remote Pods.
func parseAddress(raw string) (netip.Addr, error) {
	if len(raw) > 45 {
		return netip.Addr{}, ErrObservation
	}
	ip, err := netip.ParseAddr(raw)
	if err != nil || ip.Zone() != "" || ip.Is4In6() || ip.IsUnspecified() || ip.IsMulticast() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		return netip.Addr{}, ErrObservation
	}
	return ip, nil
}

// condition preserves an omitted API boolean as unknown, not false.
func condition(value *bool) corev1.ConditionStatus {
	if value == nil {
		return corev1.ConditionUnknown
	}
	if *value {
		return corev1.ConditionTrue
	}
	return corev1.ConditionFalse
}
