const CARTO_DARK = "https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png"

const ZoneMapHook = {
  mounted() {
    if (typeof maplibregl === "undefined") return

    this.mapReady = false
    this.pendingZone = null

    this.map = new maplibregl.Map({
      container: this.el,
      style: {
        version: 8,
        sources: {
          basemap: {
            type: "raster",
            tiles: [CARTO_DARK],
            tileSize: 256,
            maxzoom: 19
          }
        },
        layers: [{ id: "basemap", type: "raster", source: "basemap" }]
      },
      center: [45, 35],
      zoom: 2.5,
      pitchWithRotate: false,
      dragRotate: false,
      attributionControl: false
    })

    this.map.on("load", () => {
      this.mapReady = true
      const skeleton = document.getElementById("map-skeleton")
      if (skeleton) {
        skeleton.style.opacity = "0"
        setTimeout(() => { skeleton.style.display = "none" }, 420)
      }
      if (this.pendingZone) {
        this._renderZone(this.pendingZone)
        this.pendingZone = null
      }
    })

    this.map.on("error", () => {})

    this.handleEvent("render-zone", ({ zone }) => {
      if (this.mapReady) this._renderZone(zone)
      else this.pendingZone = zone
    })
  },

  destroyed() {
    if (this.map) this.map.remove()
  },

  _renderZone(zone) {
    const sid = `zone-src-${zone.id}`
    this.map.addSource(sid, {
      type: "geojson",
      data: { type: "Feature", properties: {}, geometry: zone.geojson }
    })
    this.map.addLayer({
      id: `zone-fill-${zone.id}`, type: "fill", source: sid,
      paint: { "fill-color": zone.color, "fill-opacity": zone.opacity * 1.8 }
    })
    this.map.addLayer({
      id: `zone-line-${zone.id}`, type: "line", source: sid,
      paint: { "line-color": zone.color, "line-opacity": 0.7, "line-width": 1.5, "line-dasharray": [4, 3] }
    })
    const coords = zone.geojson.coordinates[0]
    if (!coords?.length) return
    let minLng = Infinity, maxLng = -Infinity, minLat = Infinity, maxLat = -Infinity
    coords.forEach(([lng, lat]) => {
      minLng = Math.min(minLng, lng); maxLng = Math.max(maxLng, lng)
      minLat = Math.min(minLat, lat); maxLat = Math.max(maxLat, lat)
    })
    this.map.fitBounds([[minLng, minLat], [maxLng, maxLat]], { padding: 40, duration: 600, maxZoom: 5 })
  }
}

export default ZoneMapHook
