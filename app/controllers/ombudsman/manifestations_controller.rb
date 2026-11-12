# /ombudsman/manifestations (ADR 0051; contrato §5; §16 Q23, Q34, Q37, Q18):
#   GET  /ombudsman/manifestations?state[]&color[]&kind[]&channel[]&subject_id
#        &health_unit_id&q&before → { items: [<list_item>], next_before }:
#     técnico ou ouvidor; filtros repetidos nos catálogos (cor pelo
#     Deadlines.color_sql), subject_id casa o assunto e os filhos, q só o
#     protocolo exato ou o prefixo do ano ("AAAA-"); received_at DESC, id DESC,
#     páginas de PAGE, cursor `before` (CareRegulation::Cursor.encode_page).
#     Valor fora do catálogo → 422 com o path; cursor ruim → 422 invalid_cursor.
#     Não há filtro de responsável (Q37). Ids de assunto e unidade podem ir na
#     URL (Q18); texto, nome e CPF nunca.
#   GET  /ombudsman/manifestations/:id → Ombudsman::Json.detail (com `can`).
#     Sem trilha de leitura (§13): a única é a da identidade e do anexo.
#   POST /ombudsman/manifestations → 201 { id, protocol, due_on }
#     registro pela equipe (técnico ou ouvidor): canal in_person | phone |
#     ouvidorsus (Ombudsman::Register com `by:`); anexos do usuário.
#   GET  /ombudsman/manifestations/:id/receipt → { protocol, kind,
#     received_at, due_on, channel }; a anônima → 404.
# Texto, nome, contato e CPF só do corpo JSON; chave fora da lista no corpo ou
# qualquer chave na query → 422 com o path (só o nome da chave).
module Ombudsman
  class ManifestationsController < BaseController
    CREATE_KEYS = %w[kind identification_mode channel ouvidorsus_number citizen_id manifestant_name manifestant_contact
                     manifestant_cpf body health_unit_id attachment_ids].freeze

    PAGE = 50
    LIST_FILTERS = { "state" => Catalog::STATES, "color" => Catalog::COLORS, "kind" => Catalog::KINDS,
                     "channel" => Catalog::CHANNELS }.freeze
    LIST_KEYS = (LIST_FILTERS.keys + %w[subject_id health_unit_id q before]).freeze
    PROTOCOL = /\A\d{4}-\d{6,12}\z/
    YEAR_PREFIX = /\A\d{4}-\z/

    before_action :require_staff!
    before_action :load_manifestation, only: %i[show receipt]

    def index
      return unless query_only!(*LIST_KEYS)

      query = request.query_parameters
      scope = filtered(query)
      return if performed?

      settings = OmbudsmanSetting.current
      today = Time.zone.today
      colors = query["color"]
      scope = scope.where("#{Deadlines.color_sql(settings, today: today)} IN (?)", colors) if colors
      if query.key?("before")
        at, id = CareRegulation::Cursor.decode_page(query["before"])
        scope = scope.where("(ombudsman_manifestations.received_at, ombudsman_manifestations.id) < (?, ?)", at, id)
      end
      rows = scope.includes(*Json::LIST_PRELOAD).order(received_at: :desc, id: :desc).limit(PAGE + 1).to_a
      page = rows.first(PAGE)
      pending = OmbudsmanForwarding.where(ombudsman_manifestation_id: page.map(&:id), state: "pending")
                                   .group(:ombudsman_manifestation_id).count
      render json: { items: page.map { |row| Json.list_item(row, settings, today, pending) },
                     next_before: rows.size > PAGE ? CareRegulation::Cursor.encode_page(page.last.received_at, page.last.id) : nil }
    rescue CareRegulation::Cursor::Invalid
      render_refusal("before", "invalid_cursor")
    end

    def show = render_detail(@manifestation.id)

    def create
      return unless query_only!

      unknown = (body.keys - CREATE_KEYS).first
      return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      channel = body_param("channel")
      return render_refusal("channel") unless Catalog::STAFF_CHANNELS.include?(channel)

      result = Register.call(attrs: body.except("channel"), channel: channel, by: Current.user)
      return render_failure(result) if result.failure?

      manifestation = result.payload.fetch(:manifestation)
      render json: { id: manifestation.id, protocol: manifestation.protocol, due_on: due_on(manifestation) }, status: :created
    end

    def receipt
      return not_found if @manifestation.anonymous?

      render json: { protocol: @manifestation.protocol, kind: @manifestation.kind, received_at: @manifestation.received_at.iso8601,
                     due_on: due_on(@manifestation), channel: @manifestation.channel }
    end

    private

    # Os filtros da query sobre OmbudsmanManifestation (menos cor e cursor, que
    # dependem da configuração e do dia). Renderiza 422 com o path do primeiro
    # filtro inválido (e o chamador para em `performed?`).
    def filtered(query)
      scope = OmbudsmanManifestation.all
      LIST_FILTERS.each do |key, catalog|
        next unless query.key?(key)

        values = query[key]
        return render_refusal(key) unless values.is_a?(Array) && values.any? && values.all? { |v| v.is_a?(String) && catalog.include?(v) }

        scope = scope.where(key => values) unless key == "color"
      end
      %w[subject_id health_unit_id].each do |key|
        return render_refusal(key) if query.key?(key) && !uuid?(query[key])
      end
      if (subject_id = query["subject_id"])
        subjects = OmbudsmanSubject.where(id: subject_id).or(OmbudsmanSubject.where(parent_id: subject_id)).select(:id)
        scope = scope.where(subject_id: subjects)
      end
      scope = scope.where(referred_health_unit_id: query["health_unit_id"]) if query["health_unit_id"]
      if query.key?("q")
        q = query["q"]
        if q.is_a?(String) && q.match?(PROTOCOL)
          scope = scope.where(protocol: q)
        elsif q.is_a?(String) && q.match?(YEAR_PREFIX)
          scope = scope.where("ombudsman_manifestations.protocol LIKE ?", "#{q}%")
        else
          return render_refusal("q")
        end
      end
      scope
    end

    def due_on(manifestation) = Deadlines.due_on(manifestation, OmbudsmanSetting.current, today: Time.zone.today).iso8601
  end
end
