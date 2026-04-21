// ZoneMapHook — disruption zone boundary map for /disruption/:slug pages.
//
// Key design decisions:
//
// map-ready pattern — mirrors MapHook. If the map tile cache loads fast and the
// WS push arrives late (or on reconnect), we push "zone-map-ready" to the server
// so it can re-send the zone boundary data. Without this the zone fill never
// renders on fast connections.
//
// MultiPolygon safety — some zone boundaries are GeoJSON MultiPolygon, not Polygon.
// fitBounds walks all rings regardless of geometry type rather than assuming
// coordinates[0] is a flat array of positions.
//
// ResizeObserver — fires on parent size changes so the map tiles are always
// correctly laid out, including when the device is rotated.

const CARTO_DARK = "https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png"

const ZoneMapHook = {
  mounted() {
    if (typeof maplibregl === "undefined") {
      this._showError()
      return
    }

    this.mapReady = false
    this.pendingZone = null
    this._hasDrawn = false

    try {
      this.map = new maplibregl.Map({
        container: this.el,
        style: {
          version: 8,
          sources: {
            basemap: {
              type: "raster",
              tiles: [CARTO_DARK],
              tileSize: 256,
              attribution: "© OpenStreetMap contributors, © CARTO",
              maxzoom: 19
            }
          },
          layers: [{ id: "basemap", type: "raster", source: "basemap" }]
        },
        center: [45, 35],
        zoom: 2.5,
        minZoom: 1.2,
        maxZoom: 8,
        pitchWithRotate: false,
        dragRotate: false,
        attributionControl: false
      })

      this.map.addControl(
        new maplibregl.AttributionControl({ compact: true }),
        "bottom-right"
      )

      this._resizeObserver = new ResizeObserver(() => {
        if (this.map) this.map.resize()
      })
      this._resizeObserver.observe(this.el)

      this._onWindowResize = () => { if (this.map) this.map.resize() }
      window.addEventListener("resize", this._onWindowResize)

      this.map.on("load", () => {
        this.mapReady = true
        this._hideSkeleton()

        if (this.pendingZone) {
          // WS push arrived before map was ready — render from queue.
          this._renderZone(this.pendingZone)
          this._hasDrawn = true
          this.pendingZone = null
        } else {
          // Map loaded before WS push (fast tile cache, slow socket, reconnect).
          // Tell the server we are ready so it re-sends the zone boundary.
          this.pushEvent("zone-map-ready", {})
        }
      })

      this.map.on("error", (e) => {
        if (e.error && e.error.status !== 404) {
          console.warn("ZoneMapHook error:", e.error)
        }
      })

    } catch (err) {
      console.error("ZoneMapHook: init failed", err)
      this._showError()
      return
    }

    this.handleEvent("render-zone", ({ zone }) => {
      // Skip only if we have already drawn this exact zone.
      if (this._hasDrawn) return

      if (this.mapReady) {
        this._renderZone(zone)
        this._hasDrawn = true
      } else {
        this.pendingZone = zone
      }
    })
  },

  destroyed() {
    if (this._resizeObserver) this._resizeObserver.disconnect()
    if (this._onWindowResize) window.removeEventListener("resize", this._onWindowResize)
    if (this.map) this.map.remove()
  },

  _renderZone(zone) {
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
        paint: { "fill-color": zone.color, "fill-opacity": zone.opacity * 1.8 }
      })
    }

    if (!this.map.getLayer(`zone-line-${zone.id}`)) {
      this.map.addLayer({
        id: `zone-line-${zone.id}`, type: "line", source: sid,
        paint: { "line-color": zone.color, "line-opacity": 0.7, "line-width": 1.5, "line-dasharray": [4, 3] }
      })
    }

    // fitBounds: walk all coordinate rings regardless of Polygon vs MultiPolygon.
    // Polygon:      coordinates = [ring, ...holes]           ring = [[lng,lat],...]
    // MultiPolygon: coordinates = [polygon, ...]   polygon  = [ring, ...holes]
    const bounds = this._zoneBounds(zone.geojson)
    if (bounds) {
      this.map.fitBounds(bounds, { padding: 50, duration: 600, maxZoom: 5 })
    }
  },

  _zoneBounds(geojson) {
    let minLng = Infinity, maxLng = -Infinity, minLat = Infinity, maxLat = -Infinity
    let found = false

    const processRing = (ring) => {
      ring.forEach(([lng, lat]) => {
        if (typeof lng !== "number" || typeof lat !== "number") return
        minLng = Math.min(minLng, lng); maxLng = Math.max(maxLng, lng)
        minLat = Math.min(minLat, lat); maxLat = Math.max(maxLat, lat)
        found = true
      })
    }

    try {
      if (geojson.type === "Polygon") {
        geojson.coordinates.forEach(processRing)
      } else if (geojson.type === "MultiPolygon") {
        geojson.coordinates.forEach(polygon => polygon.forEach(processRing))
      }
    } catch (_) {}

    return found ? [[minLng, minLat], [maxLng, maxLat]] : null
  },

  _skeleton() {
    const id = this.el.dataset.skeletonId
    return id ? document.getElementById(id) : document.getElementById("map-skeleton")
  },

  _hideSkeleton() {
    const el = this._skeleton()
    if (!el) return
    el.style.opacity = "0"
    setTimeout(() => { el.style.display = "none" }, 420)
  },

  _showError() {
    const el = this._skeleton()
    if (el) {
      el.innerHTML = '<p style="color:#555;font-size:12px;text-align:center;padding:20px">Map unavailable</p>'
    }
  }
}

export default ZoneMapHook
