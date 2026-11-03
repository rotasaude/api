# Parâmetros do transporte e do TFD da cidade (ADR 0048). Sem cache: lidos por
# requisição.
module Transport
  module Settings
    module_function

    # -> TransportSetting (a linha 1; os padrões entram se ela falta)
    def current = TransportSetting.current

    # Forma do contrato §3 (sem allowance_codes, que é só do GET admin).
    def json(setting)
      { "tfd_min_distance_km" => setting.tfd_min_distance_km,
        "companion_rule" => { "max_age_child" => setting.companion_max_age_child,
                              "min_age_elderly" => setting.companion_min_age_elderly },
        "tfd_billing_health_unit_id" => setting.tfd_billing_health_unit_id,
        "allowance_complements" => setting.allowance_complements }
    end

    # [ { code, name, kind } ] (só leitura): nome da SIGTAP ativa da competência
    # de hoje; sem ela, o código sozinho como nome vazio-seguro ("").
    def allowance_codes
      release = Terminology::Sigtap.release_for(Time.zone.today.strftime("%Y%m"))
      names = release ? SigtapProcedure.where(release_id: release.id, code: Tfd::SigtapCodes.all).pluck(:code, :name).to_h : {}
      Tfd::SigtapCodes.entries.map { |entry| { "code" => entry[:code], "name" => names[entry[:code]] || "", "kind" => entry[:kind] } }
    end

    def admin_json(setting) = json(setting).merge("allowance_codes" => allowance_codes)
  end
end
