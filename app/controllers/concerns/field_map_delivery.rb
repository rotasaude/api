# Entrega do arquivo de mapa publicado da cidade (módulo 24c, ADR 0053;
# contrato §3.1, Q34), usada pela rota do aparelho (/field/v1/map) e pela do
# dashboard (/territory/map). Sem mapa publicado → 404 map_not_found. Sem
# trilha: o arquivo é um recorte do OpenStreetMap, sem dado de pessoa.
module FieldMapDelivery
  extend ActiveSupport::Concern

  private

  def render_field_map(map)
    return render(json: { error: "map_not_found" }, status: :not_found) unless map&.published?

    plan = FieldMaps::Delivery.plan(map: map, range: request.headers["Range"], if_none_match: request.headers["If-None-Match"],
                                    if_range: request.headers["If-Range"])
    plan.headers.except("Cache-Control").each { |name, value| response.headers[name] = value }
    # private, no-cache (Q34): o Rails normaliza o cabeçalho e descartaria o
    # `private` escrito à mão; como diretiva extra ele fica.
    response.cache_control.replace(no_cache: true, extras: [ "private" ])
    case plan.status
    when 304 then head :not_modified
    when 416
      response.headers.delete("Content-Type")
      render json: { error: "range_not_satisfiable" }, status: :range_not_satisfiable
    else
      self.status = plan.status
      self.response_body = FieldMaps::Delivery::Body.new(map.storage_key, plan.offset, plan.length)
    end
  end
end
