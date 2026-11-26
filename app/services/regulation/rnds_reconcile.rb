module Regulation
  # Reconciliação de um pedido com a RNDS pelo `GET /identifier` (módulo 26c;
  # contrato §3; pré-voo B5, B6; Review Focus 1 e 3; carry 4). Roda quando há
  # remessa sem resposta (`RndsSync.unanswered_delivery?`) e depois de um
  # EDS-MSG009. A cadeia do identificador fixo do Bundle diz o que a RNDS tem:
  #
  # - com `last_rnds_id`: a cadeia é seguida dele até a cabeça (quem o
  #   substitui, e quem substitui esse...). Cabeça `final` diferente dele →
  #   **adotada** (`:adopted`). Ninguém o substitui → `:none`;
  # - sem `last_rnds_id`: os `final` que são cabeça de uma raiz (sem
  #   `relatesTo`). Um → adotado; mais de um (duplicado, B5) → fica o da raiz
  #   mais antiga e os outros são apagados (`DELETE`, remessa `delete`), e só
  #   então a adoção (`:deduplicated`). Nenhum → `:none`.
  #
  # Adotar (B6): a remessa de documento mais recente SEM resposta depois do
  # último aceite vira aceita com o id da cabeça, e a linha passa a ter como
  # enviado o que ela levou (`sent_status`/`sent_digest` dela, `attempts 0`);
  # o `http_status` fica nulo (não houve resposta: `accepted_at` com
  # `http_status` NULL = adotada). Sem remessa sem resposta (o caminho do
  # EDS-MSG009), a linha adota só o id, com `sent_status`/`sent_digest` nulos,
  # e reenvia. `:none` fecha as remessas sem resposta com o marcador terminal
  # `not_found` (não chegaram): o GET nunca vira remessa, e a linha não fica
  # reivindicada para sempre. `:transient`/`:unauthorized`: nada muda.
  #
  # A situação da linha (`queued`/`idle`/...) é de quem chama (RndsDelivery).
  # Com `token:` (o do claim), toda gravação reconfere a posse (I2). Nada do
  # paciente nem do documento sai daqui: só ids e códigos.
  module RndsReconcile
    NOT_FOUND = "not_found".freeze
    FINAL = "final".freeze
    DOCUMENT_KINDS = %w[create replace].freeze
    NEVER = Time.utc(9999)

    module_function

    # -> :adopted | :none | :deduplicated | :transient | :unauthorized
    def call(sync:, client:, now: Time.current, token: nil,
             requester_id: IntegrationCredential.find_by(kind: "rnds_regulation")&.requester_id)
      profile = RiraProfile.current
      chain = client.identifier_chain(system: "#{profile.identifiers[:requester_prefix]}#{requester_id}",
                                      value: sync.bundle_identifier, doc_type: profile.doc_type[:value])
      return chain.status unless chain.status == :ok

      documents = chain.documents
      return from_last(sync, documents, token, now) if sync.last_rnds_id.present?

      heads = roots(documents).filter_map { |root| head_of(root.id, documents) }.select { |doc| doc.status == FINAL }.uniq(&:id)
      return none!(sync, token) if heads.empty?

      keep, *extra = heads
      extra.each do |duplicate|
        outcome = remove!(sync, duplicate.id, client, token, now)
        return outcome unless outcome == :ok
      end
      adopt!(sync, keep.id, token, now)
      extra.any? ? :deduplicated : :adopted
    end

    def from_last(sync, documents, token, now)
      head = head_of(sync.last_rnds_id, documents)
      return none!(sync, token) if head.nil? || head.id == sync.last_rnds_id || head.status != FINAL

      adopt!(sync, head.id, token, now)
      :adopted
    end

    # A cabeça da cadeia a partir de `id`: segue quem o substitui (o mais
    # antigo, se houver mais de um) até ninguém substituir. nil se nem `id`
    # nem quem o substitui aparece.
    def head_of(id, documents)
      seen = Set[id]
      current = id
      loop do
        children = documents.select { |doc| doc.replaces == current && !seen.include?(doc.id) }
        break if children.empty?

        current = children.min_by { |doc| order_key(doc, documents) }.id
        seen << current
      end
      documents.find { |doc| doc.id == current }
    end

    def roots(documents) = documents.select { |doc| doc.replaces.nil? }.sort_by { |doc| order_key(doc, documents) }

    def order_key(doc, documents)
      at = begin
        Time.iso8601(doc.date.to_s)
      rescue ArgumentError
        nil
      end
      [ at || NEVER, documents.index(doc) ]
    end

    # O duplicado sai por DELETE, com a sua remessa. EHR-ERR825 (já não é
    # final) serve: o duplicado não está mais vivo.
    def remove!(sync, rnds_id, client, token, now)
      delivery = write(sync, token) do |locked|
        RegulationRndsDelivery.create!(regulation_rnds_sync_id: locked.id, kind: "delete", rnds_id: rnds_id, sent_at: now)
      end
      response = client.delete_bundle(rnds_id)
      case response.status
      when :accepted
        delivery.update!(http_status: response.http_status || 204)
        :ok
      when :rejected
        delivery.update!(http_status: response.http_status || 422, error_codes: response.codes.presence || Rnds::Errors.codes(response.error))
        :ok
      when :unauthorized
        delivery.update!(http_status: response.http_status || 401)
        :unauthorized
      else
        delivery.update!(http_status: response.http_status) if response.http_status
        :transient
      end
    end

    def adopt!(sync, rnds_id, token, now)
      write(sync, token) do |locked|
        adopted = unanswered(locked).order(sent_at: :desc, id: :desc).first
        if adopted
          adopted.update!(accepted_at: now, rnds_id: rnds_id)
          locked.update!(last_rnds_id: rnds_id, last_accepted_at: now, sent_status: adopted.mira_status, sent_digest: adopted.digest,
                         attempts: 0, last_error_codes: [])
        else
          locked.update!(last_rnds_id: rnds_id, sent_status: nil, sent_digest: nil)
        end
      end
    end

    def none!(sync, token)
      write(sync, token) do |locked|
        unanswered(locked).where("cardinality(error_codes) = 0").find_each { |delivery| delivery.update!(error_codes: [ NOT_FOUND ]) }
      end
      :none
    end

    # Remessas de documento sem resposta depois do último aceite (o mesmo
    # critério do RndsSync.unanswered_delivery?).
    def unanswered(sync)
      scope = RegulationRndsDelivery.where(regulation_rnds_sync_id: sync.id, kind: DOCUMENT_KINDS, accepted_at: nil, http_status: nil)
                                    .where.not("? = ANY(error_codes)", NOT_FOUND)
      since = RegulationRndsDelivery.where(regulation_rnds_sync_id: sync.id).where.not(accepted_at: nil).maximum(:sent_at)
      since ? scope.where("sent_at > ?", since) : scope
    end

    def write(sync, token)
      RegulationRndsSync.transaction(requires_new: true) do
        scope = RegulationRndsSync.where(id: sync.id)
        scope = scope.where(status: "sending", claimed_at: token) if token
        locked = scope.lock("FOR UPDATE").first
        raise RegulationRndsSync::LostClaim unless locked

        yield locked
      end
    end

    private_class_method :from_last, :head_of, :roots, :order_key, :remove!, :adopt!, :none!, :unanswered, :write
  end
end
