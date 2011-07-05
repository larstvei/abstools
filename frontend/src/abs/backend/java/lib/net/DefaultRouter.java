/**
 * Copyright (c) 2009-2011, The HATS Consortium. All rights reserved. 
 * This file is licensed under the terms of the Modified BSD License.
 */
package abs.backend.java.lib.net;

import java.util.HashMap;
import java.util.Map;
import java.util.Set;

import abs.backend.java.lib.net.msg.Msg;
import abs.backend.java.lib.runtime.ABSObject;

public class DefaultRouter implements Router {
    private final Map<ABSObject, RouteEntry> nodeForObject = new HashMap<ABSObject, RouteEntry>();
    private final Map<NetCOG, RouteEntry> nodeForCOG = new HashMap<NetCOG, RouteEntry>();
    private final NetNode node;

    public DefaultRouter(NetNode node) {
	this.node = node;
    }

    @Override 
    public void update(Router adjacentNodeRouter) {
	// find new routes and replace if better than current ones
    }

    @Override
    public void register(ABSObject localObject) {
	// register the object so that messages should be routed to the current node with 0 hops
	// must throw IllegalArgumentException if localObject is already registered
    }

    @Override
    public void register(NetCOG localCOG) {
	// register the COG so that messages should be routed to the current node with 0 hops
	// must throw IllegalArgumentException if localCOG is already registered
    }
    
    @Override
    public void replace(NetCOG cog, NetNode nextNode, int hops) {
	// replace current route entry for cog with new entry 
    }

    @Override
    public void replace(ABSObject object, NetNode nextNode, int hops) {
	// replace current route entry for object with new entry 
    }
    
    @Override
    public NetNode getNextNode(Msg m) {
        return null;
    }

    @Override
    public RouteEntry getRouteEntry(NetCOG cog) {
	return nodeForCOG.get(cog);
    }

    @Override
    public RouteEntry getRouteEntry(ABSObject object) {
	return nodeForObject.get(object);
    }

    @Override
    public Set<ABSObject> getRegisteredObjects() {
	return nodeForObject.keySet();
    }

    @Override
    public Set<NetCOG> getRegisteredCOGs() {
	return nodeForCOG.keySet();
    }

}