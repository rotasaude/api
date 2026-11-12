# POST /ombudsman/manifestations/:id/classify (ADR 0051; contrato §2; §16 Q32).
# A equipe classifica (de `received`) ou reclassifica (em `in_analysis`) e a
# manifestação fica `in_analysis`:
# - `subject_id` obrigatório: assunto ativo (com o pai ativo) e folha — o
#   assunto com subassunto ativo → 422 subject_not_leaf (a lista de opções só
#   oferece os subassuntos ativos);
# - `kind`, `health_unit_id`, `professional_id` e `urgent` opcionais: chave
#   ausente mantém, `null` limpa a unidade e o profissional; a anônima continua
#   `report` (outro tipo → 422 path kind); unidade ativa; profissional com
#   vínculo ativo numa unidade ativa e conta ativa (as opções do §16 Q7).
#   Só o valor que MUDA é conferido (o que já estava gravado não é recusado).
# Uma linha `classified` por ação, `data: { changes: { campo: [antes, depois] } }`
# só com ids, rótulos e booleanos; sem mudança (reclassificação igual) nada é
# gravado. Sob Ombudsman::Lock, com `expected_state` (409 manifestation_changed).
module Ombudsman
  module Classify
    FROM = %w[received in_analysis].freeze
    OPTIONAL_IDS = %w[health_unit_id professional_id].freeze
    # campo do corpo (e do `changes`) → coluna.
    COLUMNS = { "subject_id" => :subject_id, "kind" => :kind, "health_unit_id" => :referred_health_unit_id,
                "professional_id" => :referred_professional_id, "urgent" => :urgent }.freeze

    module_function

    # -> Result.ok(manifestation:) | fail(:invalid_request, details: { path:, problems: }) | fail(:subject_not_leaf, ...)
    #  | fail(:not_found) | fail(:manifestation_changed) | fail(:invalid_transition)
    def call(manifestation_id:, expected_state:, attrs:, by:, now: Time.current)
      form = form(attrs.to_h.stringify_keys)
      return form if form.failure?

      ApplicationRecord.transaction do
        manifestation = Lock.manifestation!(manifestation_id)
        next Result.fail(:not_found) unless manifestation

        refusal = Lock.check(manifestation, expected_state)
        next refusal if refusal
        next Result.fail(:invalid_transition) unless FROM.include?(manifestation.state)

        values = form.payload
        next Input.refuse("kind") if manifestation.anonymous? && values.fetch("kind", "report") != "report"

        changes = values.each_with_object({}) do |(field, value), memo|
          before = manifestation.public_send(COLUMNS.fetch(field))
          memo[field] = [ before, value ] unless before == value
        end
        refusal = targets(changes)
        next refusal if refusal
        next Result.ok(manifestation: manifestation) if changes.empty? && manifestation.state == "in_analysis"

        manifestation.update!(changes.to_h { |field, (_, value)| [ COLUMNS.fetch(field), value ] }.merge(state: "in_analysis", updated_at: now))
        unless changes.empty?
          OmbudsmanEvent.create!(ombudsman_manifestation: manifestation, kind: "classified", actor: "staff", actor_user: by,
                                 data: { "changes" => changes }, visible_to_citizen: false, created_at: now)
        end
        Result.ok(manifestation: manifestation)
      end
    end

    # Forma do corpo, na ordem do "primeiro campo" do 422; só as chaves dadas
    # (uuids em minúsculas, como o banco os devolve).
    def form(attrs)
      return Input.refuse("subject_id") unless uuid?(attrs["subject_id"])

      values = { "subject_id" => attrs["subject_id"].downcase }
      if attrs.key?("kind")
        return Input.refuse("kind") unless Catalog::KINDS.include?(attrs["kind"])

        values["kind"] = attrs["kind"]
      end
      OPTIONAL_IDS.each do |key|
        next unless attrs.key?(key)
        return Input.refuse(key) unless attrs[key].nil? || uuid?(attrs[key])

        values[key] = attrs[key]&.downcase
      end
      if attrs.key?("urgent")
        return Input.refuse("urgent") unless [ true, false ].include?(attrs["urgent"])

        values["urgent"] = attrs["urgent"]
      end
      Result.ok(values)
    end

    # Os valores novos existem e estão ativos (Result.fail | nil).
    def targets(changes)
      if (subject_id = changes.dig("subject_id", 1))
        subject = OmbudsmanSubject.includes(:parent).find_by(id: subject_id)
        return Input.refuse("subject_id") unless subject&.active && (subject.parent.nil? || subject.parent.active)
        return Input.refuse("subject_id", :subject_not_leaf) if subject.children.active.exists?
      end
      unit_id = changes.dig("health_unit_id", 1)
      return Input.refuse("health_unit_id") if unit_id && !HealthUnit.where(active: true).exists?(id: unit_id)

      professional_id = changes.dig("professional_id", 1)
      return Input.refuse("professional_id") if professional_id && !active_professional?(professional_id)

      nil
    end

    def active_professional?(id)
      linked = ProfessionalLink.active.joins(:health_unit).where(health_units: { active: true }).select(:professional_id)
      Professional.joins(:user).where(users: { deactivated_at: nil }).where(id: id).where(id: linked).exists?
    end

    def uuid?(value) = value.is_a?(String) && value.match?(BaseController::UUID)

    private_class_method :form, :targets, :active_professional?, :uuid?
  end
end
