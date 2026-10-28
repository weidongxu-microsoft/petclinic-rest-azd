package org.springframework.samples.petclinic;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.web.WebAppConfiguration;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.context.WebApplicationContext;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.httpBasic;
import static org.springframework.security.test.web.servlet.setup.SecurityMockMvcConfigurers.springSecurity;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest(properties = {
    "spring.sql.init.mode=always",
    "spring.datasource.url=jdbc:h2:mem:azure-authentication;DB_CLOSE_DELAY=-1"
})
@ActiveProfiles({"h2", "spring-data-jpa", "azure"})
@WebAppConfiguration
class AzureAuthenticationTests {

    private static final String TEST_PASSWORD = "test-only-api-password";

    @Autowired
    private WebApplicationContext context;
    @Autowired
    private JdbcTemplate jdbc;
    @Autowired
    private PasswordEncoder encoder;

    private MockMvc mvc;

    @BeforeEach
    void setUp() {
        jdbc.update("DELETE FROM roles WHERE username = 'petclinic'");
        jdbc.update("DELETE FROM users WHERE username = 'petclinic'");
        jdbc.update("INSERT INTO users (username, password, enabled) VALUES (?, ?, ?)",
            "petclinic", encoder.encode(TEST_PASSWORD), true);
        jdbc.update("INSERT INTO roles (username, role) VALUES ('petclinic', 'ROLE_VET_ADMIN')");
        jdbc.update("UPDATE users SET enabled = false WHERE username = 'admin'");
        mvc = MockMvcBuilders.webAppContextSetup(context).apply(springSecurity()).build();
    }

    @Test
    void requiresAuthentication() throws Exception {
        mvc.perform(get("/api/vets")).andExpect(status().isUnauthorized());
    }

    @Test
    void acceptsConfiguredApiUser() throws Exception {
        mvc.perform(get("/api/vets").with(httpBasic("petclinic", TEST_PASSWORD)))
            .andExpect(status().isOk());
    }

    @Test
    void rejectsIncorrectPassword() throws Exception {
        mvc.perform(get("/api/vets").with(httpBasic("petclinic", "incorrect-test-password")))
            .andExpect(status().isUnauthorized());
    }

    @Test
    void rejectsDisabledSampleAdministrator() throws Exception {
        mvc.perform(get("/api/vets").with(httpBasic("admin", "admin")))
            .andExpect(status().isUnauthorized());
    }

    @Test
    void protectsHealthEndpoint() throws Exception {
        mvc.perform(get("/actuator/health")).andExpect(status().isUnauthorized());
    }
}
