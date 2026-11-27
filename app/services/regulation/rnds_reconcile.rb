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
  # e reenvia. Adotar é aceitar: a janela de desistência (Q16/Q25) zera.
  # `:none` fecha as remessas sem resposta com `unanswered_closed_at` (Q25:
  # não chegaram): o GET nunca vira remessa, e a linha não fica reivindicada
  # para sempre. `:transient`/`:unauthorized`: nada muda. `error_codes` só
  # guarda códigos da RNDS (Q25).
  #
  # A situação da linha (`queued`/`idle`/...) é de quem chama (RndsDelivery).
  # Com `token:` (o do claim), toda gravação reconfere a posse (I2). Nada do
  # paciente nem do documento sai daqui: só ids e códigos.
  module RndsReconcile
    FINAL = "final".freeze
    NEVER = Time.utc(9999)

    module_function

    # Os códigos de uma recusa que podem ser gravados (Q25, §9): só os da RNDS
    # (`Rnds::Errors::CODE`); sem código, nenhum (nunca o `rejected` do
    # Errors.codes nem texto).
    def rnds_codes(response)
      (response.codes.presence || Rnds::Errors.codes(response.error)).grep(Rnds::Errors::CODE)
    end

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
      return none!(sync, token, now) if heads.empty?

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
      return none!(sync, token, now) if head.nil? || head.id == sync.last_rnds_id || head.status != FINAL

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

    # O duplicado sai por DELETE, com a sua remessa. Só o 204 e a recusa com
    # EHR-ERR825 (NOT_FINAL_CODE: já não é final) contam como apagado. Outra
    # recusa 4xx deixa o duplicado `final` na RNDS: os códigos (só eles, §9)
    # vão para o `last_error_codes` da linha, o Rails.error recebe só a classe
    # e o id da linha, e a reconciliação fica por terminar (`:transient`: a
    # remessa sem resposta segue aberta e a próxima rodada, com espera, tenta
    # de novo). Nunca adota deixando o duplicado para trás.
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
        codes = rnds_codes(response)
        delivery.update!(http_status: response.http_status || 422, error_codes: codes)
        return :ok if codes.include?(RndsLimits::NOT_FINAL_CODE)

        write(sync, token) { |locked| locked.update!(last_error_codes: codes) }
        Rails.error.report(RuntimeError.new("#{name}: delete refused regulation_rnds_sync_id=#{sync.id}"), handled: true, severity: :warning)
        :transient
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
        adopted = RegulationRndsDelivery.unanswered_for(locked).order(sent_at: :desc, id: :desc).first
        if adopted
          adopted.update!(accepted_at: now, rnds_id: rnds_id)
          locked.update!(last_rnds_id: rnds_id, last_accepted_at: now, sent_status: adopted.mira_status, sent_digest: adopted.digest,
                         attempts: 0, last_error_codes: [], retry_window_started_at: nil)
        else
          locked.update!(last_rnds_id: rnds_id, sent_status: nil, sent_digest: nil)
        end
      end
    end

    def none!(sync, token, now)
      write(sync, token) do |locked|
        RegulationRndsDelivery.unanswered_for(locked).find_each { |delivery| delivery.update!(unanswered_closed_at: now) }
      end
      :none
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

    private_class_method :from_last, :head_of, :roots, :order_key, :remove!, :adopt!, :none!, :write
  end
end
