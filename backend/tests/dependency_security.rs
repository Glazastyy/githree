use std::cmp::Ordering;

const LOCKFILE: &str = include_str!("../Cargo.lock");

#[test]
fn vulnerable_dependency_versions_are_not_locked() {
    assert_locked_version_at_least("quinn-proto", "0.11.15");
    assert_locked_version_at_least("rustls-webpki", "0.103.13");
    assert_locked_version_at_least("tar", "0.4.46");
    assert_locked_version_at_least("crossbeam-epoch", "0.9.20");
    assert_locked_version_with_prefix_at_least("rand", "0.9.", "0.9.3");
    assert_locked_version_with_prefix_at_least("rand", "0.10.", "0.10.1");
}

fn assert_locked_version_at_least(package: &str, minimum: &str) {
    let version = locked_version(package).unwrap_or_else(|| panic!("{package} is not locked"));
    assert!(
        compare_versions(version, minimum) != Ordering::Less,
        "{package} {version} is below the safe minimum {minimum}"
    );
}

fn assert_locked_version_with_prefix_at_least(package: &str, prefix: &str, minimum: &str) {
    let version = locked_versions(package)
        .into_iter()
        .find(|version| version.starts_with(prefix))
        .unwrap_or_else(|| panic!("{package} {prefix}x is not locked"));
    assert!(
        compare_versions(version, minimum) != Ordering::Less,
        "{package} {version} is below the safe minimum {minimum}"
    );
}

fn locked_version(package: &str) -> Option<&'static str> {
    locked_versions(package).into_iter().next()
}

fn locked_versions(package: &str) -> Vec<&'static str> {
    LOCKFILE
        .split("\n[[package]]")
        .filter(|section| field_value(section, "name") == Some(package))
        .filter_map(|section| field_value(section, "version"))
        .collect()
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
