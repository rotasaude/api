# A lista de doenças da cidade (contrato §3): a versão da plataforma em vigor
# mais as doenças locais ativas, por nome. A plataforma é lida a cada chamada
# (a vigência muda por data); o conjunto é pequeno (~70 linhas).
module Surveillance
  module Diseases
    module_function

    def all(today: Time.zone.today)
      (platform(today: today) + LocalNotifiableDisease.active_diseases.map { |record| from_local(record) })
        .sort_by { |d| [ I18n.transliterate(d.name).downcase, d.code ] }
    end

    def find(code, today: Time.zone.today) = all(today: today).find { |d| d.code == code }

    # Doenças da versão em vigor (vazio antes da primeira vigência).
    def platform(today: Time.zone.today)
      version = DiseaseList.current(today: today)
      return [] unless version

      version.diseases.map do |d|
        Disease.new(code: d.code, name: d.name, deadline: d.deadline, cid10: d.cid10, ciap2: d.ciap2,
                    repeat_after_days: d.repeat_after_days, sinan_form: d.sinan_form, local: false,
                    list_version: version.version, notes: d.notes, id: nil, active: nil)
      end
    end

    def from_local(record)
      Disease.new(code: record.code, name: record.name, deadline: record.deadline, cid10: record.cid10, ciap2: record.ciap2,
                  repeat_after_days: record.repeat_after_days, sinan_form: nil, local: true, list_version: nil,
                  notes: nil, id: record.id, active: record.active)
    end
  end
end
