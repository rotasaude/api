# O perfil do par como as rotas do cidadão e o balcão o mostram (contratos
# §3.1, §4.4). nil sem perfil (sem birth_date ou sex). Nunca a idade.
module Citizens
  module ProfileJson
    module_function

    def call(citizen)
      return nil unless citizen.profile?

      { birth_date: citizen.birth_date, sex: citizen.sex, gender_identity: citizen.gender_identity,
        profile_source: citizen.profile_source }
    end
  end
end
