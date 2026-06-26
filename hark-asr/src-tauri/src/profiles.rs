use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tauri::Manager;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AsrProfile {
    pub id: String,
    pub name: String,
    pub backend: String,
    pub api_key: Option<String>,
    pub api_base: Option<String>,
    pub model_name: Option<String>,
    pub whisper_cpp_path: Option<String>,
    pub whisper_model_path: Option<String>,
    pub install_hint: Option<String>,
}

impl AsrProfile {
    pub fn sanitized(mut self) -> Self {
        self.api_key = Some(self.api_key.unwrap_or_default().trim().to_string());
        self.api_base = Some(self.api_base.unwrap_or_default().trim().to_string());
        self.model_name = Some(self.model_name.unwrap_or_default().trim().to_string());
        self.whisper_cpp_path = Some(self.whisper_cpp_path.unwrap_or_default().trim().to_string());
        self.whisper_model_path = Some(self.whisper_model_path.unwrap_or_default().trim().to_string());
        self.install_hint = Some(self.install_hint.unwrap_or_default().trim().to_string());
        self
    }
}

fn db_path(app_handle: &tauri::AppHandle) -> PathBuf {
    app_handle
        .path()
        .app_data_dir()
        .unwrap_or_else(|_| std::env::temp_dir().join("hark-asr"))
        .join("profiles.db")
}

pub fn init_db(app_handle: &tauri::AppHandle) -> Result<Connection, rusqlite::Error> {
    let path = db_path(app_handle);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    let conn = Connection::open(path)?;
    conn.execute(
        "CREATE TABLE IF NOT EXISTS asr_profiles (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            backend TEXT NOT NULL,
            api_key TEXT,
            api_base TEXT,
            model_name TEXT,
            whisper_cpp_path TEXT,
            whisper_model_path TEXT,
            install_hint TEXT,
            created_at INTEGER
        )",
        [],
    )?;
    Ok(conn)
}

pub fn list_profiles(conn: &Connection) -> Result<Vec<AsrProfile>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT id, name, backend, api_key, api_base, model_name, whisper_cpp_path, whisper_model_path, install_hint
         FROM asr_profiles
         ORDER BY created_at ASC"
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(AsrProfile {
            id: row.get(0)?,
            name: row.get(1)?,
            backend: row.get(2)?,
            api_key: row.get(3)?,
            api_base: row.get(4)?,
            model_name: row.get(5)?,
            whisper_cpp_path: row.get(6)?,
            whisper_model_path: row.get(7)?,
            install_hint: row.get(8)?,
        })
    })?;
    rows.collect()
}

pub fn add_profile(conn: &Connection, profile: AsrProfile) -> Result<AsrProfile, rusqlite::Error> {
    let mut profile = profile.sanitized();
    if profile.id.is_empty() {
        profile.id = uuid::Uuid::new_v4().to_string();
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    conn.execute(
        "INSERT INTO asr_profiles (id, name, backend, api_key, api_base, model_name, whisper_cpp_path, whisper_model_path, install_hint, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        params![
            profile.id,
            profile.name.trim(),
            profile.backend,
            none_if_empty(profile.api_key.as_deref()),
            none_if_empty(profile.api_base.as_deref()),
            none_if_empty(profile.model_name.as_deref()),
            none_if_empty(profile.whisper_cpp_path.as_deref()),
            none_if_empty(profile.whisper_model_path.as_deref()),
            none_if_empty(profile.install_hint.as_deref()),
            now
        ],
    )?;
    Ok(profile)
}

pub fn update_profile(conn: &Connection, profile: &AsrProfile) -> Result<(), rusqlite::Error> {
    let profile = profile.clone().sanitized();
    conn.execute(
        "UPDATE asr_profiles
         SET name = ?1,
             backend = ?2,
             api_key = ?3,
             api_base = ?4,
             model_name = ?5,
             whisper_cpp_path = ?6,
             whisper_model_path = ?7,
             install_hint = ?8
         WHERE id = ?9",
        params![
            profile.name.trim(),
            profile.backend,
            none_if_empty(profile.api_key.as_deref()),
            none_if_empty(profile.api_base.as_deref()),
            none_if_empty(profile.model_name.as_deref()),
            none_if_empty(profile.whisper_cpp_path.as_deref()),
            none_if_empty(profile.whisper_model_path.as_deref()),
            none_if_empty(profile.install_hint.as_deref()),
            profile.id
        ],
    )?;
    Ok(())
}

pub fn delete_profile(conn: &Connection, id: &str) -> Result<(), rusqlite::Error> {
    conn.execute("DELETE FROM asr_profiles WHERE id = ?1", [id])?;
    Ok(())
}

fn none_if_empty(s: Option<&str>) -> Option<&str> {
    s.filter(|v| !v.trim().is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn in_memory_conn() -> Connection {
        Connection::open_in_memory().unwrap()
    }

    fn create_test_table(conn: &Connection) {
        conn.execute(
            "CREATE TABLE asr_profiles (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                backend TEXT NOT NULL,
                api_key TEXT,
                api_base TEXT,
                model_name TEXT,
                whisper_cpp_path TEXT,
                whisper_model_path TEXT,
                install_hint TEXT,
                created_at INTEGER
            )",
            [],
        )
        .unwrap();
    }

    #[test]
    fn test_profile_crud() {
        let conn = in_memory_conn();
        create_test_table(&conn);

        let profile = AsrProfile {
            id: String::new(),
            name: "Test OpenAI".to_string(),
            backend: "OpenAiWhisper".to_string(),
            api_key: Some("sk-test".to_string()),
            api_base: Some("https://api.example.com/v1".to_string()),
            model_name: Some("whisper-1".to_string()),
            whisper_cpp_path: None,
            whisper_model_path: None,
            install_hint: Some("自定义接入说明".to_string()),
        };

        let added = add_profile(&conn, profile).unwrap();
        assert!(!added.id.is_empty());

        let list = list_profiles(&conn).unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].name, "Test OpenAI");
        assert_eq!(list[0].api_key.as_deref(), Some("sk-test"));

        let mut updated = list[0].clone();
        updated.name = "Updated".to_string();
        updated.api_key = Some("sk-new".to_string());
        update_profile(&conn, &updated).unwrap();

        let list = list_profiles(&conn).unwrap();
        assert_eq!(list[0].name, "Updated");
        assert_eq!(list[0].api_key.as_deref(), Some("sk-new"));

        delete_profile(&conn, &list[0].id).unwrap();
        let list = list_profiles(&conn).unwrap();
        assert!(list.is_empty());
    }

    #[test]
    fn test_empty_fields_are_stored_as_null() {
        let conn = in_memory_conn();
        create_test_table(&conn);

        let profile = AsrProfile {
            id: String::new(),
            name: "Empty Fields".to_string(),
            backend: "MlxQwen3".to_string(),
            api_key: Some("   ".to_string()),
            api_base: Some("".to_string()),
            model_name: None,
            whisper_cpp_path: None,
            whisper_model_path: None,
            install_hint: None,
        };

        let added = add_profile(&conn, profile).unwrap();
        let list = list_profiles(&conn).unwrap();
        assert_eq!(list[0].id, added.id);
        assert!(list[0].api_key.is_none());
        assert!(list[0].api_base.is_none());
    }
}
