# Configuração do cabeçalho do arquivo (contrato §6 com B10): admin municipal,
# step-up no controlador. Larguras do layout (cbc-rsp 30, cbc-sgl 6, cbc-dst
# 40) medidas no texto já transliterado como no arquivo (BpaFile.plain_text,
# §13 E20) e recusadas, nunca cortadas, com o campo; CNPJ com DV válido e só
# numérico (cbc-cgccpf é NUM: o CNPJ alfanumérico da Receita não cabe);
# indicador M/E. Linha única (singleton); a corrida de criação tenta de novo
# uma vez só (T10).
module Billing
  module SaveSettings
    LIMITS = { "origin_name" => 30, "origin_acronym" => 6, "destination_body" => 40 }.freeze
    REQUIRED = %w[origin_name destination_body].freeze
    MANAGEMENT = %w[M E].freeze

    module_function

    def call(params:, by:)
      texts = LIMITS.keys.to_h { |field| [ field, params[field].is_a?(String) ? params[field].squish : "" ] }
      LIMITS.each do |field, limit|
        return Result.fail(:field_required, details: { field: field }) if REQUIRED.include?(field) && texts[field].empty?
        return Result.fail(:too_long, details: { field: field }) if BpaFile.plain_text(texts[field]).length > limit
      end
      cnpj = params["origin_cnpj"].is_a?(String) ? Cnpj.normalize(params["origin_cnpj"]) : nil
      return Result.fail(:invalid_cnpj) unless cnpj&.match?(/\A\d{14}\z/)
      return Result.fail(:invalid_management) unless MANAGEMENT.include?(params["management"])

      retried = false
      begin
        settings = save!(texts, cnpj, params["management"], by)
      rescue ActiveRecord::RecordNotUnique
        raise if retried # duas criações simultâneas da linha única: a segunda tentativa acha a linha; mais que isso não é corrida

        retried = true
        retry
      end
      Result.ok(settings: settings)
    end

    def save!(texts, cnpj, management, by)
      ApplicationRecord.transaction do
        settings = BillingSetting.lock.find_by(singleton: true) || BillingSetting.new(singleton: true)
        settings.update!(origin_name: texts["origin_name"], origin_acronym: texts["origin_acronym"].presence, origin_cnpj: cnpj,
                         destination_body: texts["destination_body"], management: management, updated_by_user: by)
        DomainEvents.publish("billing_settings.changed", billing_setting_id: settings.id, user_id: by.id)
        settings
      end
    end
    private_class_method :save!
  end
end
