// MapLibre GL JS hook for Pathfinder route visualization.
// maplibregl loaded as global via CDN in root layout.
//
// Key design decisions:
//
// Visibility guard — mounted() exits early if offsetWidth===0.  This prevents
// the mobile map panel (md:hidden, display:none on desktop) from initialising
// a full MapLibre instance on desktop.
//
// Re-render guard — _renderRoutes fingerprints incoming route IDs.  Identical
// payloads are skipped so switching the mobile tab never triggers redundant GL
// work.
//
// Animated line draw — the selected route arc draws in over ~800ms using
// requestAnimationFrame + progressive source data updates. Non-selected routes
// render immediately.
//
// Origin/dest markers — maplibregl.Marker with custom HTML pills showing the
// IATA codes, positioned at the first/last geojson coordinates.
//
// Zone pulse — a gentle sin-wave opacity animation on advisory zone fills,
// making them feel "live" rather than static decoration.

const CARTO_DARK = "https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png"
const CARTO_ATTR = "© OpenStreetMap contributors, © CARTO"

function buildStyle() {
  return {
    version: 8,
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
    // ── Visibility guard ──────────────────────────────────────────────────
    // Skip initialisation when this element (or an ancestor) is display:none.
    // On desktop, the mobile map panel has offsetWidth===0 via md:hidden.
    if (this.el.offsetWidth === 0 && this.el.offsetHeight === 0) {
      this._skipped = true
      return
    }

    if (typeof maplibregl === "undefined") {
      console.warn("Pathfinder: maplibregl not loaded")
      this._showMapError()
      return
    }

    this.routeData   = []
    this.selectedId  = null
    this.mapReady    = false
    this.pendingRender = null
    this.lastRouteIds  = null
    this._markers    = []
    this._animFrame  = null
    this._pulseFrame = null

    console.time(`map-init:${this.el.id}`)

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

      // ResizeObserver: fires when the element changes size — including when a
      // display:none parent becomes visible again (tab switch back to map panel).
      this._resizeObserver = new ResizeObserver(() => {
        if (this.map) this.map.resize()
      })
      this._resizeObserver.observe(this.el)

      requestAnimationFrame(() => {
        requestAnimationFrame(() => { if (this.map) this.map.resize() })
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
        requestAnimationFrame(() => { if (this.map) this.map.resize() })
        console.timeEnd(`map-init:${this.el.id}`)
        this._hideSkeleton()
        if (this.pendingRender) {
          this._renderRoutes(this.pendingRender)
          this.pendingRender = null
        }
      })

      this.map.on("error", (e) => {
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
      // ── Re-render guard ───────────────────────────────────────────────
      const incomingIds = (data.routes || []).map(r => r.id).sort().join(",")
      if (incomingIds === this.lastRouteIds) return
      this.lastRouteIds = incomingIds

      if (this.map) this.map.resize()
      console.time(`map-render:${this.el.id}`)

      if (this.mapReady) {
        this._renderRoutes(data)
        console.timeEnd(`map-render:${this.el.id}`)
      } else {
        this.pendingRender = data
      }
    })

    this.handleEvent("highlight-route", ({ id }) => {
      this._highlightRoute(id)
    })
  },

  destroyed() {
    if (this._skipped) return
    this._cancelAnimations()
    if (this._markers) this._markers.forEach(m => m.remove())
    if (this.map) this.map.remove()
    if (this._resizeObserver) this._resizeObserver.disconnect()
    if (this._onWindowResize) window.removeEventListener("resize", this._onWindowResize)
  },

  // ── Render pipeline ───────────────────────────────────────────────────────

  _renderRoutes({ routes, zones, selected_id }) {
    this.routeData  = routes
    this.selectedId = selected_id
    this._clearDynamicLayers()
    this._addZoneOverlays(zones || [])
    this._addRouteLines(routes, selected_id)
    this._addMarkers(routes)
    this._fitBounds(routes)
    if (zones && zones.length > 0) this._startZonePulse(zones)
  },

  _clearDynamicLayers() {
    this._cancelAnimations()

    // Remove HTML markers
    if (this._markers) { this._markers.forEach(m => m.remove()); this._markers = [] }

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

  _cancelAnimations() {
    if (this._animFrame)  { cancelAnimationFrame(this._animFrame);  this._animFrame  = null }
    if (this._pulseFrame) { cancelAnimationFrame(this._pulseFrame); this._pulseFrame = null }
  },

  // ── Zone overlays + pulse ─────────────────────────────────────────────────

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
          paint: { "fill-color": zone.color, "fill-opacity": 0.12 }
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

  // Breathing animation on zone fill opacity (0.07 → 0.22 → 0.07, ~3s cycle).
  // More pronounced than before so zones feel clearly "active" on the map.
  _startZonePulse(zones) {
    let tick = 0
    const pulse = () => {
      tick++
      const alpha = 0.07 + 0.15 * ((Math.sin(tick * 0.035) + 1) / 2) // 0.07–0.22, period ≈ 3s
      zones.forEach(zone => {
        if (this.map && this.map.getLayer(`zone-fill-${zone.id}`)) {
          this.map.setPaintProperty(`zone-fill-${zone.id}`, "fill-opacity", alpha)
        }
      })
      this._pulseFrame = requestAnimationFrame(pulse)
    }
    this._pulseFrame = requestAnimationFrame(pulse)
  },

  // ── Route lines ───────────────────────────────────────────────────────────

  _addRouteLines(routes, selectedId) {
    routes.forEach(route => {
      const sid = `route-src-${route.id}`
      const isSelected = route.id === selectedId
      const arcCoords  = this._buildArc(route.geojson.coordinates)

      // Add source with the first 2 points only — the animated draw will
      // progressively fill in the rest for the selected route.
      const initialGeom = {
        type: "Feature",
        properties: { id: route.id },
        geometry: { type: "LineString", coordinates: arcCoords.slice(0, 2) }
      }

      if (!this.map.getSource(sid)) {
        this.map.addSource(sid, { type: "geojson", data: initialGeom })
      } else {
        this.map.getSource(sid).setData(initialGeom)
      }

      // Glow layer (selected routes only — adds depth)
      if (!this.map.getLayer(`route-glow-${route.id}`)) {
        this.map.addLayer({
          id: `route-glow-${route.id}`, type: "line", source: sid,
          paint: {
            "line-color": route.color,
            "line-opacity": isSelected ? 0.30 : 0,
            "line-width": 12,
            "line-blur": 10
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
            "line-opacity": isSelected ? 1.0 : 0.25,
            "line-width": isSelected ? 3.5 : 1.5,
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

      // Animate the selected route drawing in; show others immediately
      if (isSelected) {
        this._animateRouteDraw(sid, route.id, arcCoords)
      } else {
        this.map.getSource(sid).setData({
          type: "Feature",
          properties: { id: route.id },
          geometry: { type: "LineString", coordinates: arcCoords }
        })
      }
    })
  },

  // Draws the route arc progressively over ~800ms using requestAnimationFrame.
  // Runs ~50 frames, updating the GeoJSON source with an increasing slice of
  // the coordinate array. Gives users a clear sense of the route's direction.
  _animateRouteDraw(sourceId, routeId, arcCoords) {
    const total   = arcCoords.length
    const frames  = 50
    const step    = Math.max(1, Math.ceil(total / frames))
    let   drawn   = 2

    const tick = () => {
      drawn = Math.min(drawn + step, total)
      const src = this.map && this.map.getSource(sourceId)
      if (!src) return
      src.setData({
        type: "Feature",
        properties: { id: routeId },
        geometry: { type: "LineString", coordinates: arcCoords.slice(0, drawn) }
      })
      if (drawn < total) {
        this._animFrame = requestAnimationFrame(tick)
      } else {
        this._animFrame = null
      }
    }
    this._animFrame = requestAnimationFrame(tick)
  },

  // ── Origin / destination markers ──────────────────────────────────────────

  // Adds IATA code pill markers at the first and last coordinates of each route.
  // Origin: white/neutral pill.  Destination: colored pill matching route color.
  // Positioned at "bottom" anchor so the pill sits above the coordinate point.
  _addMarkers(routes) {
    this._markers = this._markers || []
    this._markers.forEach(m => m.remove())
    this._markers = []

    routes.forEach(route => {
      const coords = route.geojson && route.geojson.coordinates
      if (!coords || coords.length < 2) return

      const [oLng, oLat] = coords[0]
      const [dLng, dLat] = coords[coords.length - 1]

      const originLabel = route.origin_iata || "○"
      const destLabel   = route.dest_iata   || "●"

      // Origin marker — white pill, neutral feel
      const originEl = this._markerEl(originLabel, "rgba(240,240,240,0.92)", "#111", route.origin_name)
      this._markers.push(
        new maplibregl.Marker({ element: originEl, anchor: "bottom", offset: [0, -4] })
          .setLngLat([oLng, oLat])
          .addTo(this.map)
      )

      // Destination marker — route color, draws attention to the endpoint
      const destEl = this._markerEl(destLabel, route.color || "#10b981", "#fff", route.dest_name)
      this._markers.push(
        new maplibregl.Marker({ element: destEl, anchor: "bottom", offset: [0, -4] })
          .setLngLat([dLng, dLat])
          .addTo(this.map)
      )
    })
  },

  _markerEl(iata, bg, color, title) {
    const el = document.createElement("div")
    el.title = title || ""
    Object.assign(el.style, {
      background:     bg,
      color:          color,
      padding:        "2px 7px",
      borderRadius:   "5px",
      fontSize:       "11px",
      fontWeight:     "700",
      letterSpacing:  "0.07em",
      whiteSpace:     "nowrap",
      boxShadow:      "0 2px 8px rgba(0,0,0,0.55)",
      border:         "1.5px solid rgba(255,255,255,0.18)",
      pointerEvents:  "none",
      userSelect:     "none",
      fontFamily:     "ui-monospace, 'Cascadia Code', monospace"
    })
    el.textContent = iata
    return el
  },

  // ── Highlight + bounds ────────────────────────────────────────────────────

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
        this.map.setPaintProperty(glowId, "line-opacity", isSelected ? 0.30 : 0)
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

  // ── Skeleton helpers ──────────────────────────────────────────────────────

  _skeleton() {
    const id = this.el.dataset.skeletonId
    return id ? document.getElementById(id) : null
  },

  _hideSkeleton() {
    const el = this._skeleton()
    if (!el) return
    el.style.opacity = "0"
    setTimeout(() => { el.style.display = "none" }, 520)
  },

  _showMapError() {
    const el = this._skeleton()
    if (el) {
      el.innerHTML = '<p style="color:#555;font-size:12px;text-align:center;padding:20px">Map unavailable</p>'
    }
  },

  // ── Great-circle arc (slerp) ──────────────────────────────────────────────

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

      const dLat = lat2 - lat1, dLon = lon2 - lon1
      const a = Math.sin(dLat / 2) ** 2 +
                Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2
      const d = 2 * Math.asin(Math.sqrt(a))

      const pts = s < coordinates.length - 2 ? n : n + 1

      for (let i = 0; i < pts; i++) {
        const t = i / n
        if (d < 1e-6) {
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
