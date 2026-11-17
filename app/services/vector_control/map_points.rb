# Pontos do mapa da vigilância ambiental (módulo 35a, ADR 0054; contrato §17;
# Q8, Q13(7)): `points: [{ id, latitude, longitude, category, label }]` de uma
# camada, com o ponto do domicílio do 24c (a `location` da versão atual;
# domicílio sem ponto fica fora). Só domicílios ativos.
#   - risk (neighborhood_id): os domicílios com perfil num quarteirão do
#     bairro; category = risk_class ou "none"; label = número do quarteirão;
#   - ovitraps (neighborhood_id, epi_week "YYYY-WW"): as ovitrampas ativas dos
#     quarteirões do bairro, no ponto do domicílio; id = da ovitrampa;
#     category pela leitura da semana (a da palheta instalada mais tarde):
#     negative (0 ovos), positive, alert (≥ ovitrap_alert_eggs) ou not_counted
#     (sem leitura contada); label = "<número> · <ovos>" ("—" sem contagem);
#   - transmission (transmission_block_id): os domicílios dos quarteirões da
#     área do bloqueio (as linhas da confirmação ou, sem linha, a sugestão de
#     anéis, como o Json.transmission_blocks); category = "area"; label =
#     número do quarteirão. NUNCA o caso: nem paciente, nem notificação, nem
#     qual domicílio tem caso.
# Sigilo: nenhum nome, endereço ou pessoa; a coordenada nunca sai junto de
# caso. `trail` = { micro_area_id => [household_id] } dos domicílios cujo
# ponto saiu, para a trilha territory_map (quem chama grava).
# Consultas constantes por camada.
# -> Result.ok(points:, trail:) | Result.fail(:invalid_request, path:) | Result.fail(:not_found)
module VectorControl
  module MapPoints
    LAYERS = { "risk" => %w[neighborhood_id], "ovitraps" => %w[neighborhood_id epi_week],
               "transmission" => %w[transmission_block_id] }.freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    NONE = "none".freeze
    AREA = "area".freeze

    module_function

    def build(layer, params:)
      raise ArgumentError, "layer #{layer}" unless LAYERS.key?(layer)

      params = params.to_h.stringify_keys
      LAYERS.fetch(layer).each do |key|
        next if key == "epi_week"
        return invalid(key) unless params[key].is_a?(String) && params[key].match?(UUID)
      end
      public_send(layer, params)
    end

    def risk(params)
      neighborhood = Neighborhood.find_by(id: params["neighborhood_id"])
      return Result.fail(:not_found) unless neighborhood

      rows = HouseholdVectorProfile.joins(:household, :city_block)
                                   .where(households: { status: "active" }, city_blocks: { neighborhood_id: neighborhood.id })
                                   .order(:household_id)
                                   .pluck(:household_id, "households.micro_area_id", :risk_class, "city_blocks.number")
      household_points(rows.map { |id, area, risk, number| [ id, area, risk || NONE, number ] })
    end

    def ovitraps(params)
      week = Surveillance::EpiWeek.parse(params["epi_week"])
      return invalid("epi_week") unless week

      neighborhood = Neighborhood.find_by(id: params["neighborhood_id"])
      return Result.fail(:not_found) unless neighborhood

      traps = Ovitrap.active_ovitraps.joins(:city_block, :household)
                     .where(city_blocks: { neighborhood_id: neighborhood.id }, households: { status: "active" })
                     .order(:id).pluck(:id, :number, :household_id, "households.micro_area_id")
      eggs = OvitrapReading.where(ovitrap_id: traps.map(&:first), epi_week: OvitrapIndex.column(week))
                           .order(:ovitrap_id, installed_on: :desc, created_at: :desc, id: :desc)
                           .pluck(:ovitrap_id, :egg_count)
                           .each_with_object({}) { |(id, count), map| map[id] = count unless map.key?(id) }
      alert = Parameters.current.values.fetch("ovitrap_alert_eggs") { Parameters.defaults.fetch("ovitrap_alert_eggs") }.to_i
      locations = locations(traps.map { |row| row[2] })
      trail = Hash.new { |hash, key| hash[key] = [] }
      points = traps.filter_map do |id, number, household_id, micro_area_id|
        location = locations[household_id]
        next unless location

        trail[micro_area_id] << household_id unless trail[micro_area_id].include?(household_id)
        count = eggs[id]
        point(id, location, egg_category(count, alert), "#{number} · #{count.nil? ? '—' : count}")
      end
      Result.ok(points: points, trail: trail.to_h)
    end

    def transmission(params)
      block = TransmissionBlock.find_by(id: params["transmission_block_id"])
      return Result.fail(:not_found) unless block

      rows = HouseholdVectorProfile.joins(:household, :city_block)
                                   .where(households: { status: "active" }, city_block_id: area_ids(block))
                                   .order(:household_id)
                                   .pluck(:household_id, "households.micro_area_id", "city_blocks.number")
      household_points(rows.map { |id, area, number| [ id, area, AREA, number ] })
    end

    # rows = [[household_id, micro_area_id, category, label]]
    def household_points(rows)
      locations = locations(rows.map(&:first))
      trail = Hash.new { |hash, key| hash[key] = [] }
      points = rows.filter_map do |household_id, micro_area_id, category, label|
        location = locations[household_id]
        next unless location

        trail[micro_area_id] << household_id
        point(household_id, location, category, label)
      end
      Result.ok(points: points, trail: trail.to_h)
    end

    # { household_id => location } das versões atuais com ponto (cifrado: lido em Ruby).
    def locations(household_ids)
      return {} if household_ids.empty?

      HouseholdVersion.joins(:household).where(household_id: household_ids.uniq)
                      .where("household_versions.version = households.version")
                      .select("household_versions.id", "household_versions.household_id", "household_versions.location")
                      .each_with_object({}) { |version, map| map[version.household_id] = version.location if version.location }
    end

    # A área do bloqueio: as linhas gravadas ou, sem linha, a sugestão de anéis
    # em volta do centro, só com os quarteirões ativos.
    def area_ids(block)
      ids = TransmissionBlockArea.where(transmission_block_id: block.id).pluck(:city_block_id)
      return ids if ids.any? || block.center_block_id.nil?

      rings = Parameters.current.values.fetch("block_radius_rings").to_i
      CityBlock.active_blocks.where(id: Rings.around([ block.center_block_id ], rings: rings)).pluck(:id)
    end

    def egg_category(count, alert)
      if count.nil? then "not_counted"
      elsif count.zero? then "negative"
      elsif count >= alert then "alert"
      else "positive"
      end
    end

    def point(id, location, category, label)
      { id: id, latitude: location.fetch("latitude"), longitude: location.fetch("longitude"), category: category, label: label }
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })
  end
end
