# CNPJ da cidade (Desvio 12; contrato §6): obrigatório na receita de
# enfermagem (city_cnpj_missing). O resto do perfil não muda por aqui.
module ClinicalDocuments
  class CityProfilesController < BaseController
    before_action :require_reader_role, only: :show
    before_action :require_admin_role, only: :update
    before_action :require_step_up!, only: :update
    before_action :set_profile

    def show = render(json: json)

    def update
      cnpj = Cnpj.normalize(body["cnpj"])
      return unprocessable("invalid_cnpj") unless cnpj

      @profile.update!(cnpj: cnpj)
      render json: json
    end

    private

    def set_profile
      @profile = CityProfile.current
      not_found unless @profile
    end

    def json = { name: @profile.name, cnpj: @profile.cnpj }
  end
end
