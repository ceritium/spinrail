class I18nTest < Rieles::IntegrationTest
  def test_english_defaults
    get "/i18n"
    assert_select "h1", "Translations"
    assert_select "p.greeting", "Hello, Ana!"
    assert_select "p.errors", "Title is too short (minimum is 3 characters) / Author must exist"
    assert_select "p.saved", "translation missing: en.i18n.show.saved"
    assert_select "p.locale", "en"
  end

  def test_spanish
    get "/i18n?locale=es"
    assert_select "h1", "Traducciones"
    assert_select "p.greeting", "¡Hola, Ana!"
    assert_select "p.errors", "Título es demasiado corto (3 caracteres mínimo) / Author must exist"
    assert_select "p.saved", "Guardado"
  end

  def test_locale_resets_between_requests
    get "/i18n?locale=es"
    get "/i18n"
    assert_select "p.locale", "en"
  end
end
