// MapLibre GL JS hook for Pathfinder route visualization.
// maplibregl loaded as global via CDN in root layout.

const CARTO_DARK = "https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png"
const CARTO_ATTR = "© OpenStreetMap contributors, © CARTO"

function buildStyle() {
  return {
    version: 8,
    // No glyphs — we render no text labels on this map
    sources: {
      basemap: {
        type: "raster",
        tiles: [CARTO_DARK],
        tileSize: 256,
        attribution: CARTO_ATTR,
        maxzoom: 19
      }
    },
    layers: [{
      id: "basemap",
      type: "raster",
      source: "basemap",
      paint: { "raster-opacity": 1 }
    }]
  }
}

const MapHook = {
  mounted() {
    if (typeof maplibregl === "undefined") {
      console.warn("Pathfinder: maplibregl not loaded")
      this._showMapError()
      return
    }

    this.routeData = []
    this.selectedId = null
    this.mapReady = false
    this.pendingRender = null

    try {
      this.map = new maplibregl.Map({
        container: this.el,
        style: buildStyle(),
        center: [55, 35],
        zoom: 2.0,
        minZoom: 1.2,
        maxZoom: 8,
        pitchWithRotate: false,
        dragRotate: false,
        attributionControl: false
      })

      // ResizeObserver: handles flex layout changes and container resizes
      this._resizeObserver = new ResizeObserver(() => {
        if (this.map) this.map.resize()
      })
      this._resizeObserver.observe(this.el)

      // Double rAF: mounted() can run before the browser finalises flex heights
      // (especially on desktop where md:h-full depends on a computed flex chain).
      // Two animation frames ensure the layout is settled before MapLibre reads
      // offsetHeight — this is the main fix for the blank results-page map.
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          if (this.map) this.map.resize()
        })
      })

      this._onWindowResize = () => { if (this.map) this.map.resize() }
      window.addEventListener("resize", this._onWindowResize)

      this.map.addControl(
        new maplibregl.AttributionControl({ compact: true }),
        "bottom-right"
      )

      this.map.on("load", () => {
        this.mapReady = true
        this.map.resize()
        // Second resize via rAF catches any remaining layout settling after style load
        requestAnimationFrame(() => { if (this.map) this.map.resize() })
        this._hideSkeleton()
        if (this.pendingRender) {
          this._renderRoutes(this.pendingRender)
          this.pendingRender = null
        }
      })

      this.map.on("error", (e) => {
        // Tile errors are non-fatal — only log, don't crash
        if (e.error && e.error.status !== 404) {
          console.warn("Pathfinder map error:", e.error)
        }
      })

    } catch (err) {
      console.error("Pathfinder: map init failed", err)
      this._showMapError()
      return
    }

    this.handleEvent("render-routes", (data) => {
      // Ensure canvas dimensions are current before rendering — catches the case
      // where the map was created before the flex container had its final height.
      if (this.map) this.map.resize()
      if (this.mapReady) {
        this._renderRoutes(data)
      } else {
        this.pendingRender = data
      }
    })

    this.handleEvent("highlight-route", ({ id }) => {
      this._highlightRoute(id)
    })
  },

  destroyed() {
    if (this.map) this.map.remove()
    if (this._resizeObserver) this._resizeObserver.disconnect()
    if (this._onWindowResize) window.removeEventListener("resize", this._onWindowResize)
  },

  _hideSkeleton() {
    const skeleton = document.getElementById("map-skeleton")
    if (!skeleton) return
    skeleton.style.opacity = "0"
    skeleton.style.transition = "opacity 0.4s"
    setTimeout(() => { skeleton.style.display = "none" }, 420)
  },

  _showMapError() {
    const skeleton = document.getElementById("map-skeleton")
    if (skeleton) {
      skeleton.innerHTML = '<p style="color:#666;font-size:12px;text-align:center;padding:20px">Map unavailable</p>'
    }
  },

  _renderRoutes({ routes, zones, selected_id }) {
    this.routeData = routes
    this.selectedId = selected_id
    this._clearDynamicLayers()
    this._addZoneOverlays(zones || [])
    this._addRouteLines(routes, selected_id)
    this._fitBounds(routes)
  },

  _clearDynamicLayers() {
    const style = this.map.getStyle()
    if (!style) return
    const toRemove = style.layers
      .filter(l => l.id.startsWith("route-") || l.id.startsWith("zone-"))
      .map(l => l.id)
    toRemove.forEach(id => { if (this.map.getLayer(id)) this.map.removeLayer(id) })
    Object.keys(style.sources)
      .filter(s => s.startsWith("route-") || s.startsWith("zone-"))
      .forEach(id => { if (this.map.getSource(id)) this.map.removeSource(id) })
  },

  _addZoneOverlays(zones) {
    zones.forEach(zone => {
      const sid = `zone-src-${zone.id}`
      if (!this.map.getSource(sid)) {
        this.map.addSource(sid, {
          type: "geojson",
          data: { type: "Feature", properties: {}, geometry: zone.geojson }
        })
      }
      if (!this.map.getLayer(`zone-fill-${zone.id}`)) {
        this.map.addLayer({
          id: `zone-fill-${zone.id}`, type: "fill", source: sid,
          paint: { "fill-color": zone.color, "fill-opacity": zone.opacity }
        })
      }
      if (!this.map.getLayer(`zone-line-${zone.id}`)) {
        this.map.addLayer({
          id: `zone-line-${zone.id}`, type: "line", source: sid,
          paint: { "line-color": zone.color, "line-opacity": 0.5, "line-width": 1, "line-dasharray": [3, 3] }
        })
      }
    })
  },

  _addRouteLines(routes, selectedId) {
    routes.forEach(route => {
      const sid = `route-src-${route.id}`
      const isSelected = route.id === selectedId
      const coords = this._buildArc(route.geojson.coordinates)

      const geojsonData = {
        type: "Feature",
        properties: { id: route.id },
        geometry: { type: "LineString", coordinates: coords }
      }

      if (!this.map.getSource(sid)) {
        this.map.addSource(sid, { type: "geojson", data: geojsonData })
      } else {
        this.map.getSource(sid).setData(geojsonData)
      }

      // Glow layer (selected only)
      if (!this.map.getLayer(`route-glow-${route.id}`)) {
        this.map.addLayer({
          id: `route-glow-${route.id}`, type: "line", source: sid,
          paint: {
            "line-color": route.color,
            "line-opacity": isSelected ? 0.25 : 0,
            "line-width": 8,
            "line-blur": 6
          },
          layout: { "line-cap": "round", "line-join": "round" }
        })
      }

      // Main line
      if (!this.map.getLayer(`route-line-${route.id}`)) {
        this.map.addLayer({
          id: `route-line-${route.id}`, type: "line", source: sid,
          paint: {
            "line-color": route.color,
            "line-opacity": isSelected ? 1.0 : 0.30,
            "line-width": isSelected ? 3 : 1.5,
            "line-dasharray": isSelected ? [1] : [5, 4]
          },
          layout: { "line-cap": "round", "line-join": "round" }
        })
      }

      this.map.on("click", `route-line-${route.id}`, () => {
        this.pushEvent("route-clicked-on-map", { id: String(route.id) })
        this._highlightRoute(route.id)
        this._scrollToCard(route.id)
      })
      this.map.on("mouseenter", `route-line-${route.id}`, () => {
        this.map.getCanvas().style.cursor = "pointer"
      })
      this.map.on("mouseleave", `route-line-${route.id}`, () => {
        this.map.getCanvas().style.cursor = ""
      })
    })
  },

  _highlightRoute(selectedId) {
    this.selectedId = selectedId
    this.routeData.forEach(route => {
      const isSelected = route.id === selectedId
      const lineId = `route-line-${route.id}`
      const glowId = `route-glow-${route.id}`
      if (this.map.getLayer(lineId)) {
        this.map.setPaintProperty(lineId, "line-opacity", isSelected ? 1.0 : 0.30)
        this.map.setPaintProperty(lineId, "line-width", isSelected ? 3 : 1.5)
        this.map.setPaintProperty(lineId, "line-dasharray", isSelected ? [1] : [5, 4])
      }
      if (this.map.getLayer(glowId)) {
        this.map.setPaintProperty(glowId, "line-opacity", isSelected ? 0.25 : 0)
      }
    })
  },

  _fitBounds(routes) {
    if (!routes.length) return
    let minLng = Infinity, maxLng = -Infinity, minLat = Infinity, maxLat = -Infinity
    routes.forEach(r => r.geojson.coordinates.forEach(([lng, lat]) => {
      minLng = Math.min(minLng, lng); maxLng = Math.max(maxLng, lng)
      minLat = Math.min(minLat, lat); maxLat = Math.max(maxLat, lat)
    }))
    this.map.fitBounds(
      [[minLng, minLat], [maxLng, maxLat]],
      { padding: { top: 50, bottom: 50, left: 70, right: 70 }, duration: 700, maxZoom: 5 }
    )
  },

  _scrollToCard(routeId) {
    const el = document.getElementById(`route-card-${routeId}`)
    if (el) el.scrollIntoView({ behavior: "smooth", block: "nearest" })
  },

  // Great-circle arc: spherical linear interpolation (slerp) between each waypoint pair.
  // Routes naturally curve along the Earth's surface — long east-west segments arc
  // poleward correctly, matching actual flight paths rather than adding an artificial
  // lat-bulge that could visually cut through Russia or other closed airspace.
  _buildArc(coordinates, n = 60) {
    if (coordinates.length < 2) return coordinates

    const toRad = d => d * Math.PI / 180
    const toDeg = r => r * 180 / Math.PI
    const out = []

    for (let s = 0; s < coordinates.length - 1; s++) {
      const [lon1d, lat1d] = coordinates[s]
      const [lon2d, lat2d] = coordinates[s + 1]
      const lon1 = toRad(lon1d), lat1 = toRad(lat1d)
      const lon2 = toRad(lon2d), lat2 = toRad(lat2d)

      // Haversine angular distance between the two points
      const dLat = lat2 - lat1, dLon = lon2 - lon1
      const a = Math.sin(dLat / 2) ** 2 +
                Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2
      const d = 2 * Math.asin(Math.sqrt(a))

      // Include the last point only on the final segment to avoid duplicates
      const pts = s < coordinates.length - 2 ? n : n + 1

      for (let i = 0; i < pts; i++) {
        const t = i / n
        if (d < 1e-6) {
          // Points are essentially identical — linear fallback
          out.push([lon1d + (lon2d - lon1d) * t, lat1d + (lat2d - lat1d) * t])
          continue
        }
        const A = Math.sin((1 - t) * d) / Math.sin(d)
        const B = Math.sin(t * d) / Math.sin(d)
        const x = A * Math.cos(lat1) * Math.cos(lon1) + B * Math.cos(lat2) * Math.cos(lon2)
        const y = A * Math.cos(lat1) * Math.sin(lon1) + B * Math.cos(lat2) * Math.sin(lon2)
        const z = A * Math.sin(lat1) + B * Math.sin(lat2)
        out.push([
          toDeg(Math.atan2(y, x)),
          toDeg(Math.atan2(z, Math.sqrt(x * x + y * y)))
        ])
      }
    }

    return out
  }
}

export default MapHook
