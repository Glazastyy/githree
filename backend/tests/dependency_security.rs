use std::cmp::Ordering;

const LOCKFILE: &str = include_str!("../Cargo.lock");

#[test]
fn vulnerable_dependency_versions_are_not_locked() {
    assert_locked_version_at_least("quinn-proto", "0.11.15");
    assert_locked_version_at_least("rustls-webpki", "0.103.13");
    assert_locked_version_at_least("tar", "0.4.46");
    assert_locked_version_at_least("crossbeam-epoch", "0.9.20");
}

fn assert_locked_version_at_least(package: &str, minimum: &str) {
    let version = locked_version(package).unwrap_or_else(|| panic!("{package} is not locked"));
    assert!(
        compare_versions(version, minimum) != Ordering::Less,
        "{package} {version} is below the safe minimum {minimum}"
    );
}

fn locked_version(package: &str) -> Option<&'static str> {
    LOCKFILE
        .split("\n[[package]]")
        .find(|section| field_value(section, "name") == Some(package))
        .and_then(|section| field_value(section, "version"))
}

fn field_value<'a>(section: &'a str, field: &str) -> Option<&'a str> {
    section.lines().find_map(|line| {
        let (key, value) = line.split_once(" = ")?;
        (key == field).then(|| value.trim_matches('"'))
    })
}

fn compare_versions(left: &str, right: &str) -> Ordering {
    let left_parts = version_parts(left);
    let right_parts = version_parts(right);
    left_parts.cmp(&right_parts)
}

fn version_parts(version: &str) -> Vec<u64> {
    version
        .split('.')
        .map(|part| part.parse::<u64>().unwrap_or(0))
        .collect()
}
