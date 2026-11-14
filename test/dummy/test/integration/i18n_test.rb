class I18nTest < Rieles::IntegrationTest
  def test_english_defaults
    get "/i18n"
    assert_select "h1", "Translations"
    assert_select "p.greeting", "Hello, Ana!"
    assert_select "p.errors", "Title is too short (minimum is 3 characters) / Author must exist"
    assert_select "p.saved", "translation missing: en.i18n.show.saved"
    assert_select "p.locale", "en"
    assert_select "p.plural", "No comments | 1 comment | 5 comments"
    assert_select "p.date", "04/03 05:06 2026-03-04 05:06:07"
  end

  def test_spanish
    get "/i18n?locale=es"
    assert_select "h1", "Traducciones"
    assert_select "p.greeting", "¡Hola, Ana!"
    assert_select "p.errors", "Título es demasiado corto (3 caracteres mínimo) / Author must exist"
    assert_select "p.saved", "Guardado"
  end

  def test_accept_language_and_number_formats
    get "/i18n", headers: { "Accept-Language" => "fr-FR, es;q=0.8, en;q=0.5" }
    assert_select "p.locale", "es"
    assert_select "p.money", "€1.234.567,50"
    get "/i18n"
    assert_select "p.money", "$1,234,567.50"
  end

  def test_locale_resets_between_requests
    get "/i18n?locale=es"
    get "/i18n"
    assert_select "p.locale", "en"
  end
end
