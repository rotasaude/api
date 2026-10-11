# Módulo 20 (ADR 0035): a cidade com a linha do tempo, a configuração do PEC
# e a URL assinada como o PEC monta (HMAC-SHA256 hex da URL até o
# pec_timestamp; ver docs/pesquisa/2026-10-11-pec-sistemas-externos.md).
module TimelineHelpers
  PEC_KEY = "chave-de-teste-do-pec-0123456789abcdef".freeze
  PEC_ORIGIN = "https://pec.cidade.gov.br".freeze

  def timeline_city!(record_mode: "record", clinical_record: true, documents: false, pec: false)
    city = clinical_city!(record_mode: record_mode, enabled: clinical_record)
    maintainer = ledi_maintainer!
    Platform::Features.set!(city: city, key: "patient_timeline", enabled: true, maintainer: maintainer)
    Platform::Features.set!(city: city, key: "clinical_documents", enabled: true, maintainer: maintainer) if documents
    Platform::Features.set!(city: city, key: "pec_external_view", enabled: true, maintainer: maintainer) if pec
    CityCatalog.reset_cache!
    city
  end

  def pec_settings!(origin: PEC_ORIGIN, key: PEC_KEY)
    setting = PecSetting.current || PecSetting.new
    setting.update!(pec_origin: origin, pec_origin_updated_at: Time.current, hmac_key: key,
                    hmac_key_updated_at: key && Time.current)
    setting
  end

  def signed_pec_path(professional:, citizen:, cnes:, at: Time.current, key: PEC_KEY, host: test_city_host)
    unsigned = "http://#{host}/pec/timeline?documento-profissional=#{professional}" \
               "&documento-cidadao=#{citizen}&cnes=#{cnes}&pec_timestamp=#{at.to_i}"
    "#{unsigned}&pec_sign=#{OpenSSL::HMAC.hexdigest('SHA256', key, unsigned)}"
  end
end

RSpec.configure { |c| c.include TimelineHelpers }
